@preconcurrency import AVFoundation
import Foundation

enum AudioCaptureAdmissionPolicy {
    static func allowsCapture(
        isPreparingForTermination: Bool,
        isPaused: Bool,
        screenVisibility: ScreenContextVisibility,
        privacyCleanupInProgress: Bool
    ) -> Bool {
        !isPreparingForTermination
            && !isPaused
            && screenVisibility != .private
            && !privacyCleanupInProgress
    }

    static func allowsMeetingSystemAudio(
        isPreparingForTermination: Bool,
        isPaused: Bool,
        screenVisibility: ScreenContextVisibility,
        privacyCleanupInProgress: Bool,
        isMeetingContext: Bool,
        meetingDetectionEnabled: Bool,
        isAudioActiveNow: Bool
    ) -> Bool {
        allowsCapture(
            isPreparingForTermination: isPreparingForTermination,
            isPaused: isPaused,
            screenVisibility: screenVisibility,
            privacyCleanupInProgress: privacyCleanupInProgress
        )
            && screenVisibility == .available
            && isMeetingContext
            && meetingDetectionEnabled
            && isAudioActiveNow
    }
}

final class AudioCaptureService: @unchecked Sendable {
    typealias Handler = @Sendable (Data, TimeInterval) async -> Void

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private let callbackTracker = AsyncCallbackTracker()
    private var segmenter = SpeechSegmenter()
    private var handler: Handler?
    private(set) var isRunning = false

    func start(handler: @escaping Handler) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return }
        callbackTracker.resumeAccepting()
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
            callbackTracker.stopAccepting()
            throw error
        }
    }

    func stop(flushPendingSegment: Bool = true) {
        lock.withLock {
            guard isRunning else { return }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            let pending = flushPendingSegment ? segmenter.finish() : nil
            let callback = handler
            segmenter.reset()
            handler = nil
            isRunning = false
            guard let pending, let callback else { return }
            // Register while holding the same lock used by `consume`. A
            // concurrent stop can no longer close the tracker between segment
            // extraction and callback registration.
            callbackTracker.submit {
                await callback(WAVEncoder.encode(pending), pending.voicedDuration)
            }
        }
        callbackTracker.stopAccepting()
    }

    func stopAndDrain(flushPendingSegment: Bool = true, cancelCallbacks: Bool = false) async {
        stop(flushPendingSegment: flushPendingSegment)
        await callbackTracker.drain(cancel: cancelCallbacks)
    }

    /// Clears samples accumulated before a privacy boundary without stopping
    /// the microphone. Subsequent allowed audio starts a fresh segment.
    func discardPendingSegment() {
        lock.lock()
        segmenter.reset()
        lock.unlock()
    }

    /// Closes the current speech segment without stopping the microphone. The
    /// caller can await durable handoff before changing meeting metadata.
    func flushPendingSegment() async {
        let task: Task<Void, Never>? = lock.withLock {
            let segment = segmenter.finish()
            let callback = handler
            segmenter.reset()
            guard let segment, let callback else { return nil }
            return callbackTracker.submit {
                await callback(WAVEncoder.encode(segment), segment.voicedDuration)
            }
        }
        await task?.value
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
        lock.withLock {
            let segments = segmenter.process(samples: mono, sampleRate: buffer.format.sampleRate)
            guard let callback = handler else { return }
            // Every extracted segment is registered before stop can acquire the
            // service lock and stop accepting callbacks. Encoding happens in the
            // task, outside the realtime tap's critical section.
            for segment in segments {
                callbackTracker.submit {
                    await callback(WAVEncoder.encode(segment), segment.voicedDuration)
                }
            }
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
