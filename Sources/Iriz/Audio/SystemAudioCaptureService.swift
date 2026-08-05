@preconcurrency import AudioToolbox
@preconcurrency import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

actor SystemAudioCaptureService {
    private var stream: SCStream?
    private var output: SystemAudioOutput?
    private var lifecycleGeneration = 0
    private var isStarting = false

    func start(handler: @escaping AudioCaptureService.Handler) async throws {
        guard stream == nil, !isStarting else { return }
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        isStarting = true
        defer {
            if lifecycleGeneration == generation { isStarting = false }
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard lifecycleGeneration == generation else { return }
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
        guard lifecycleGeneration == generation, !Task.isCancelled else {
            try? await stream.stopCapture()
            await output.finish(flushPendingSegment: false)
            return
        }
        self.output = output
        self.stream = stream
    }

    func stop(flushPendingSegment: Bool = true) async {
        lifecycleGeneration += 1
        isStarting = false
        let stream = self.stream
        let output = self.output
        self.stream = nil
        self.output = nil
        guard let stream else {
            if let output { await output.finish(flushPendingSegment: flushPendingSegment) }
            return
        }
        try? await stream.stopCapture()
        if let output {
            await output.finish(flushPendingSegment: flushPendingSegment)
        }
    }
}

private final class SystemAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.iriz.system-audio", qos: .utility)
    private let lock = NSLock()
    private let callbackTracker = AsyncCallbackTracker()
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
            callbackTracker.submit { [handler] in
                await handler(data, segment.voicedDuration)
            }
        }
    }

    func finish(flushPendingSegment: Bool = true) async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
        callbackTracker.stopAccepting()
        let segment = lock.withLock {
            let pending = flushPendingSegment ? segmenter.finish() : nil
            segmenter.reset()
            return pending
        }
        if let segment {
            let data = WAVEncoder.encode(segment)
            await handler(data, segment.voicedDuration)
        }
        await callbackTracker.drain(cancel: !flushPendingSegment)
    }
}

enum SystemAudioCaptureError: LocalizedError {
    case noDisplay

    var errorDescription: String? { "No display is available for meeting audio capture." }
}
