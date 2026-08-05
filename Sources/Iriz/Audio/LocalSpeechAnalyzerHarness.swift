@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

enum LocalSpeechAnalyzerAvailability: String, Equatable, Sendable {
    case available
    case unavailable
    case unsupportedLocale
    case assetsNotInstalled
    case assetsDownloading
}

struct LocalSpeechAnalyzerProviderStatus: Equatable, Sendable {
    var availability: LocalSpeechAnalyzerAvailability
    var resolvedLocaleIdentifier: String?
    var fingerprint: SpeechAnalyzerModelFingerprint?
}

protocol LocalSpeechAnalyzerProviding: Sendable {
    func status(for locale: Locale) async -> LocalSpeechAnalyzerProviderStatus
    func transcribe(wavData: Data, locale: Locale) async throws -> String
}

enum LocalSpeechAnalyzerProviderError: Error, Equatable {
    case unavailable(LocalSpeechAnalyzerAvailability)
    case invalidWAV
    case unsupportedAudioFormat
    case noCompatibleAudioFormat
    case conversionFailed
    case emptyTranscript
}

/// The live macOS 26 implementation. It never downloads assets and never writes
/// the WAV segment to disk; audio is decoded and converted in memory.
actor AppleSpeechAnalyzerProvider: LocalSpeechAnalyzerProviding {
    func status(for locale: Locale) async -> LocalSpeechAnalyzerProviderStatus {
        guard SpeechTranscriber.isAvailable else {
            return LocalSpeechAnalyzerProviderStatus(availability: .unavailable)
        }
        guard let resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return LocalSpeechAnalyzerProviderStatus(availability: .unsupportedLocale)
        }

        let transcriber = SpeechTranscriber(locale: resolvedLocale, preset: .transcription)
        let assetStatus = await AssetInventory.status(forModules: [transcriber])
        let availability: LocalSpeechAnalyzerAvailability = switch assetStatus {
        case .installed: .available
        case .downloading: .assetsDownloading
        case .supported: .assetsNotInstalled
        case .unsupported: .unsupportedLocale
        @unknown default: .unavailable
        }
        return LocalSpeechAnalyzerProviderStatus(
            availability: availability,
            resolvedLocaleIdentifier: resolvedLocale.identifier,
            fingerprint: availability == .available ? .current() : nil
        )
    }

    func transcribe(wavData: Data, locale: Locale) async throws -> String {
        let providerStatus = await status(for: locale)
        guard providerStatus.availability == .available,
              let localeIdentifier = providerStatus.resolvedLocaleIdentifier else {
            throw LocalSpeechAnalyzerProviderError.unavailable(providerStatus.availability)
        }

        let resolvedLocale = Locale(identifier: localeIdentifier)
        let transcriber = SpeechTranscriber(locale: resolvedLocale, preset: .transcription)
        let modules: [any SpeechModule] = [transcriber]
        let sourceBuffer = try MonoPCM16WAVDecoder.decode(wavData)
        guard let analysisFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules,
            considering: sourceBuffer.format
        ) else {
            throw LocalSpeechAnalyzerProviderError.noCompatibleAudioFormat
        }
        let analysisBuffer = try AudioBufferConverter.convert(sourceBuffer, to: analysisFormat)
        let analyzer = SpeechAnalyzer(
            modules: modules,
            options: SpeechAnalyzer.Options(priority: .utility, modelRetention: .whileInUse)
        )
        try await analyzer.prepareToAnalyze(in: analysisFormat)

        let resultTask = Task<String, Error> {
            var finalizedText: [String] = []
            for try await result in transcriber.results {
                guard result.isFinal else { continue }
                let text = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { finalizedText.append(text) }
            }
            return finalizedText.joined(separator: " ")
        }
        let inputs = AsyncStream<AnalyzerInput> { continuation in
            continuation.yield(AnalyzerInput(buffer: analysisBuffer))
            continuation.finish()
        }

        do {
            if let finalTime = try await analyzer.analyzeSequence(inputs) {
                try await analyzer.finalizeAndFinish(through: finalTime)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            let transcript = try await resultTask.value
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else { throw LocalSpeechAnalyzerProviderError.emptyTranscript }
            return transcript
        } catch {
            resultTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }
}

struct LocalSpeechAnalyzerHarnessConfiguration: Equatable, Sendable {
    /// Developer/RC qualification must opt in explicitly. Runtime routing also
    /// supplies the code-reviewed profiles embedded in the signed app version.
    var isEnabled = false
    var allowedLanguageCodes: Set<String> = ["en", "fr"]
    var requiresApprovedProfile = false
    var approvedProfiles: [SpeechAnalyzerQualificationProfile] = []
}

enum LocalSpeechAnalyzerSkipReason: Equatable, Sendable {
    case disabled
    case meeting
    case unsupportedLanguage
    case unqualifiedModel
    case provider(LocalSpeechAnalyzerAvailability)
}

struct LocalSpeechAnalyzerTranscript: Equatable, Sendable {
    var text: String
    var languageCode: String
    var fingerprint: SpeechAnalyzerModelFingerprint
    var latencyMilliseconds: Int
}

enum LocalSpeechAnalyzerAttempt: Equatable, Sendable {
    case skipped(LocalSpeechAnalyzerSkipReason)
    case completed(LocalSpeechAnalyzerTranscript)
    case failed
}

/// Injectable facade shared by offline qualification and the production route.
/// It never promotes a profile; runtime callers must provide profiles embedded
/// in the signed app and exact matching happens before transcription begins.
struct LocalSpeechAnalyzerQualificationHarness: Sendable {
    var configuration: LocalSpeechAnalyzerHarnessConfiguration
    private let provider: any LocalSpeechAnalyzerProviding

    init(
        configuration: LocalSpeechAnalyzerHarnessConfiguration = LocalSpeechAnalyzerHarnessConfiguration(),
        provider: any LocalSpeechAnalyzerProviding = AppleSpeechAnalyzerProvider()
    ) {
        self.configuration = configuration
        self.provider = provider
    }

    func transcribe(
        wavData: Data,
        languageTag: String,
        isMeeting: Bool
    ) async -> LocalSpeechAnalyzerAttempt {
        guard configuration.isEnabled else { return .skipped(.disabled) }
        guard !isMeeting else { return .skipped(.meeting) }
        let languageCode = SpeechAnalyzerQualificationRecord.normalizedLanguageCode(languageTag)
        guard configuration.allowedLanguageCodes.contains(languageCode) else {
            return .skipped(.unsupportedLanguage)
        }

        let locale = Locale(identifier: languageTag)
        let providerStatus = await provider.status(for: locale)
        guard providerStatus.availability == .available,
              let fingerprint = providerStatus.fingerprint else {
            return .skipped(.provider(providerStatus.availability))
        }
        if configuration.requiresApprovedProfile {
            guard configuration.approvedProfiles.contains(where: {
                $0.accepts(fingerprint: fingerprint, languageCode: languageCode)
            }) else {
                return .skipped(.unqualifiedModel)
            }
        }

        let startedAt = ContinuousClock.now
        do {
            let transcript = try await provider.transcribe(wavData: wavData, locale: locale)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else { return .failed }
            let duration = startedAt.duration(to: .now)
            return .completed(LocalSpeechAnalyzerTranscript(
                text: transcript,
                languageCode: languageCode,
                fingerprint: fingerprint,
                latencyMilliseconds: Self.milliseconds(duration)
            ))
        } catch {
            return .failed
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        let whole = components.seconds * 1_000
        let fractional = components.attoseconds / 1_000_000_000_000_000
        return max(0, Int(whole + fractional))
    }
}

private enum MonoPCM16WAVDecoder {
    static func decode(_ data: Data) throws -> AVAudioPCMBuffer {
        guard data.count >= 44,
              ascii(data, at: 0) == "RIFF",
              ascii(data, at: 8) == "WAVE" else {
            throw LocalSpeechAnalyzerProviderError.invalidWAV
        }

        var offset = 12
        var formatDescription: (channels: UInt16, sampleRate: UInt32, bitsPerSample: UInt16)?
        var pcmRange: Range<Int>?
        while offset + 8 <= data.count {
            let identifier = ascii(data, at: offset)
            let chunkSize = Int(uint32(data, at: offset + 4))
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + chunkSize
            guard payloadEnd <= data.count else { throw LocalSpeechAnalyzerProviderError.invalidWAV }

            if identifier == "fmt ", chunkSize >= 16 {
                guard uint16(data, at: payloadStart) == 1 else {
                    throw LocalSpeechAnalyzerProviderError.unsupportedAudioFormat
                }
                formatDescription = (
                    channels: uint16(data, at: payloadStart + 2),
                    sampleRate: uint32(data, at: payloadStart + 4),
                    bitsPerSample: uint16(data, at: payloadStart + 14)
                )
            } else if identifier == "data" {
                pcmRange = payloadStart..<payloadEnd
            }
            offset = payloadEnd + (chunkSize.isMultiple(of: 2) ? 0 : 1)
        }

        guard let description = formatDescription,
              description.channels == 1,
              description.sampleRate > 0,
              description.bitsPerSample == 16,
              let pcmRange,
              !pcmRange.isEmpty,
              pcmRange.count.isMultiple(of: 2),
              let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Double(description.sampleRate),
                channels: 1,
                interleaved: true
              ) else {
            throw LocalSpeechAnalyzerProviderError.unsupportedAudioFormat
        }

        let frameCount = pcmRange.count / MemoryLayout<Int16>.size
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ), let destination = buffer.int16ChannelData?[0] else {
            throw LocalSpeechAnalyzerProviderError.unsupportedAudioFormat
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for frame in 0..<frameCount {
            let byteOffset = pcmRange.lowerBound + frame * 2
            destination[frame] = Int16(bitPattern: uint16(data, at: byteOffset))
        }
        return buffer
    }

    private static func ascii(_ data: Data, at offset: Int) -> String {
        guard offset >= 0, offset + 4 <= data.count else { return "" }
        return String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
    }

    private static func uint16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}

private enum AudioBufferConverter {
    static func convert(_ source: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if source.format == targetFormat { return source }
        guard let converter = AVAudioConverter(from: source.format, to: targetFormat) else {
            throw LocalSpeechAnalyzerProviderError.conversionFailed
        }
        let rateRatio = targetFormat.sampleRate / source.format.sampleRate
        let outputCapacity = AVAudioFrameCount(ceil(Double(source.frameLength) * rateRatio)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            throw LocalSpeechAnalyzerProviderError.conversionFailed
        }

        let inputState = ConverterInputState()
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if !inputState.takeInput() {
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            return source
        }
        guard conversionError == nil,
              status == .haveData || status == .inputRanDry || status == .endOfStream,
              output.frameLength > 0 else {
            throw LocalSpeechAnalyzerProviderError.conversionFailed
        }
        return output
    }
}

private final class ConverterInputState: @unchecked Sendable {
    private let lock = NSLock()
    private var isAvailable = true

    func takeInput() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isAvailable else { return false }
        isAvailable = false
        return true
    }
}
