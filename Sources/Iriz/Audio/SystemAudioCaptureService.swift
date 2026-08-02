@preconcurrency import AudioToolbox
@preconcurrency import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

actor SystemAudioCaptureService {
    private var stream: SCStream?
    private var output: SystemAudioOutput?

    func start(handler: @escaping AudioCaptureService.Handler) async throws {
        guard stream == nil else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw SystemAudioCaptureError.noDisplay }
        let excluded = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.queueDepth = 1
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        configuration.captureMicrophone = false

        let output = SystemAudioOutput(handler: handler)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
        try await stream.startCapture()
        self.output = output
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
        output?.finish()
        output = nil
    }
}

private final class SystemAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.iriz.system-audio", qos: .utility)
    private let lock = NSLock()
    private var segmenter = SpeechSegmenter()
    private let handler: AudioCaptureService.Handler

    init(handler: @escaping AudioCaptureService.Handler) {
        self.handler = handler
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio,
              sampleBuffer.isValid,
              let format = sampleBuffer.formatDescription,
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format) else { return }

        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
        )
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &list,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )
        guard status == noErr,
              let pointer = list.mBuffers.mData else { return }

        let sampleRate = description.pointee.mSampleRate
        let isFloat = description.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let samples: [Float]
        if isFloat {
            let count = Int(list.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
            samples = Array(UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: Float.self), count: count))
        } else {
            let count = Int(list.mBuffers.mDataByteSize) / MemoryLayout<Int16>.size
            let values = UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: Int16.self), count: count)
            samples = values.map { Float($0) / Float(Int16.max) }
        }

        lock.lock()
        let segments = segmenter.process(samples: samples, sampleRate: sampleRate)
        lock.unlock()
        for segment in segments {
            let data = WAVEncoder.encode(segment)
            Task { await handler(data, segment.voicedDuration) }
        }
    }

    func finish() {
        lock.lock()
        let segment = segmenter.finish()
        segmenter.reset()
        lock.unlock()
        if let segment {
            let data = WAVEncoder.encode(segment)
            Task { await handler(data, segment.voicedDuration) }
        }
    }
}

enum SystemAudioCaptureError: LocalizedError {
    case noDisplay

    var errorDescription: String? { "No display is available for meeting audio capture." }
}
