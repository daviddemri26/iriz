import Foundation

struct SpeechSegment: Equatable, Sendable {
    var samples: [Float]
    var sampleRate: Double
    var voicedDuration: TimeInterval
}

struct SpeechSegmenter: Sendable {
    var speechThreshold: Float = 0.012
    var closingSilence: TimeInterval = 1.2
    var preRollDuration: TimeInterval = 0.35
    var minimumVoicedDuration: TimeInterval = 0.35
    var maximumDuration: TimeInterval = 180

    private var preRoll: [Float] = []
    private var current: [Float] = []
    private var silentSamples = 0
    private var voicedSamples = 0
    private var sampleRate: Double?
    private var speaking = false

    mutating func process(samples: [Float], sampleRate newSampleRate: Double) -> [SpeechSegment] {
        guard !samples.isEmpty, newSampleRate > 0 else { return [] }
        if sampleRate != newSampleRate {
            reset()
            sampleRate = newSampleRate
        }
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        let containsSpeech = rms >= speechThreshold
        var segments: [SpeechSegment] = []

        if speaking {
            current.append(contentsOf: samples)
            if containsSpeech {
                voicedSamples += samples.count
                silentSamples = 0
            } else {
                silentSamples += samples.count
            }
            if Double(silentSamples) / newSampleRate >= closingSilence ||
                Double(current.count) / newSampleRate >= maximumDuration {
                if let segment = finalize() { segments.append(segment) }
            }
        } else if containsSpeech {
            speaking = true
            current = preRoll + samples
            voicedSamples = samples.count
            silentSamples = 0
            preRoll.removeAll(keepingCapacity: true)
        } else {
            preRoll.append(contentsOf: samples)
            let maximum = Int(preRollDuration * newSampleRate)
            if preRoll.count > maximum { preRoll.removeFirst(preRoll.count - maximum) }
        }
        return segments
    }

    mutating func finish() -> SpeechSegment? {
        finalize()
    }

    mutating func reset() {
        preRoll.removeAll(keepingCapacity: true)
        current.removeAll(keepingCapacity: true)
        silentSamples = 0
        voicedSamples = 0
        speaking = false
        sampleRate = nil
    }

    private mutating func finalize() -> SpeechSegment? {
        defer {
            current.removeAll(keepingCapacity: true)
            silentSamples = 0
            voicedSamples = 0
            speaking = false
        }
        guard let sampleRate,
              Double(voicedSamples) / sampleRate >= minimumVoicedDuration else { return nil }
        let removableSilence = max(silentSamples - Int(0.2 * sampleRate), 0)
        if removableSilence > 0 && current.count >= removableSilence {
            current.removeLast(removableSilence)
        }
        return SpeechSegment(
            samples: current,
            sampleRate: sampleRate,
            voicedDuration: Double(voicedSamples) / sampleRate
        )
    }
}

enum WAVEncoder {
    static func encode(_ segment: SpeechSegment) -> Data {
        let normalized = segment.samples.map { min(max($0, -1), 1) }
        var pcm = Data(capacity: normalized.count * 2)
        for value in normalized {
            let sample = Int16(value * Float(Int16.max))
            pcm.appendLittleEndian(sample)
        }
        let sampleRate = UInt32(segment.sampleRate.rounded())
        let byteRate = sampleRate * 2
        var data = Data()
        data.appendASCII("RIFF")
        data.appendLittleEndian(UInt32(36 + pcm.count))
        data.appendASCII("WAVEfmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(UInt16(2))
        data.appendLittleEndian(UInt16(16))
        data.appendASCII("data")
        data.appendLittleEndian(UInt32(pcm.count))
        data.append(pcm)
        return data
    }

    static func cappedForVoiceReference(_ data: Data, maximumSeconds: Int = 10) -> Data {
        guard data.count > 44, maximumSeconds > 0 else { return data }
        let sampleRate = UInt32(data[24]) | UInt32(data[25]) << 8 | UInt32(data[26]) << 16 | UInt32(data[27]) << 24
        let bytesPerSample = Int(UInt16(data[32]) | UInt16(data[33]) << 8)
        guard sampleRate > 0, bytesPerSample > 0 else { return data }
        let maximumPCMBytes = Int(sampleRate) * bytesPerSample * maximumSeconds
        let pcmCount = min(data.count - 44, maximumPCMBytes)
        var output = Data(data.prefix(44 + pcmCount))
        output.replaceLittleEndian(UInt32(36 + pcmCount), at: 4)
        output.replaceLittleEndian(UInt32(pcmCount), at: 40)
        return output
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(Data(string.utf8))
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func replaceLittleEndian<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        var littleEndian = value.littleEndian
        let replacement = Swift.withUnsafeBytes(of: &littleEndian) { Data($0) }
        replaceSubrange(offset..<(offset + replacement.count), with: replacement)
    }
}
