@preconcurrency import AVFoundation
import Foundation

final class AudioCaptureService: @unchecked Sendable {
    typealias Handler = @Sendable (Data, TimeInterval) async -> Void

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var segmenter = SpeechSegmenter()
    private var handler: Handler?
    private(set) var isRunning = false

    func start(handler: @escaping Handler) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return }
        self.handler = handler
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioCaptureError.noInput
        }
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
            isRunning = true
        } catch {
            input.removeTap(onBus: 0)
            self.handler = nil
            throw error
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let segment = segmenter.finish(), let handler {
            let data = WAVEncoder.encode(segment)
            Task { await handler(data, segment.voicedDuration) }
        }
        segmenter.reset()
        handler = nil
        isRunning = false
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let count = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: count)
        for channel in 0..<channelCount {
            let values = channels[channel]
            for index in 0..<count { mono[index] += values[index] / Float(channelCount) }
        }
        lock.lock()
        let segments = segmenter.process(samples: mono, sampleRate: buffer.format.sampleRate)
        let callback = handler
        lock.unlock()
        for segment in segments {
            guard let callback else { continue }
            let data = WAVEncoder.encode(segment)
            Task { await callback(data, segment.voicedDuration) }
        }
    }
}

enum AudioCaptureError: LocalizedError {
    case noInput

    var errorDescription: String? {
        switch self {
        case .noInput: "No microphone input is available."
        }
    }
}
