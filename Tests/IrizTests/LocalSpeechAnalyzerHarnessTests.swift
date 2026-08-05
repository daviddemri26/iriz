import Foundation
import Testing
@testable import Iriz

@Suite("Local SpeechAnalyzer qualification harness")
struct LocalSpeechAnalyzerHarnessTests {
    @Test("The local harness is disabled by default")
    func disabledByDefault() async {
        let provider = FakeLocalSpeechAnalyzerProvider(status: .available(fingerprint))
        let harness = LocalSpeechAnalyzerQualificationHarness(provider: provider)

        let attempt = await harness.transcribe(
            wavData: Data([1, 2, 3]),
            languageTag: "en-US",
            isMeeting: false
        )

        #expect(attempt == .skipped(.disabled))
        let statusCalls = await provider.statusCallCount
        let transcriptionCalls = await provider.transcriptionCallCount
        #expect(statusCalls == 0)
        #expect(transcriptionCalls == 0)
    }

    @Test("Meetings always stay outside the local harness")
    func meetingsAreExcluded() async {
        let provider = FakeLocalSpeechAnalyzerProvider(status: .available(fingerprint))
        let harness = LocalSpeechAnalyzerQualificationHarness(
            configuration: .init(isEnabled: true),
            provider: provider
        )

        let attempt = await harness.transcribe(
            wavData: Data([1, 2, 3]),
            languageTag: "fr-FR",
            isMeeting: true
        )

        #expect(attempt == .skipped(.meeting))
        let statusCalls = await provider.statusCallCount
        let transcriptionCalls = await provider.transcriptionCallCount
        #expect(statusCalls == 0)
        #expect(transcriptionCalls == 0)
    }

    @Test("An available injected provider transcribes only eligible FR or EN segments")
    func providerInjection() async {
        let provider = FakeLocalSpeechAnalyzerProvider(
            status: .available(fingerprint),
            transcript: "  I will send the proposal tomorrow.  "
        )
        let harness = LocalSpeechAnalyzerQualificationHarness(
            configuration: .init(isEnabled: true),
            provider: provider
        )

        let attempt = await harness.transcribe(
            wavData: Data([1, 2, 3]),
            languageTag: "en-US",
            isMeeting: false
        )

        guard case .completed(let transcript) = attempt else {
            Issue.record("Expected a completed local transcript")
            return
        }
        #expect(transcript.text == "I will send the proposal tomorrow.")
        #expect(transcript.languageCode == "en")
        #expect(transcript.fingerprint == fingerprint)
        #expect(transcript.latencyMilliseconds >= 0)
        let statusCalls = await provider.statusCallCount
        let transcriptionCalls = await provider.transcriptionCallCount
        #expect(statusCalls == 1)
        #expect(transcriptionCalls == 1)
    }

    @Test("Missing assets and unsupported languages fail closed without transcription")
    func unavailableProvider() async {
        let provider = FakeLocalSpeechAnalyzerProvider(status: .assetsNotInstalled)
        let harness = LocalSpeechAnalyzerQualificationHarness(
            configuration: .init(isEnabled: true),
            provider: provider
        )

        let missingAssets = await harness.transcribe(
            wavData: Data([1]),
            languageTag: "fr-FR",
            isMeeting: false
        )
        let unsupportedLanguage = await harness.transcribe(
            wavData: Data([1]),
            languageTag: "de-DE",
            isMeeting: false
        )

        #expect(missingAssets == .skipped(.provider(.assetsNotInstalled)))
        #expect(unsupportedLanguage == .skipped(.unsupportedLanguage))
        let statusCalls = await provider.statusCallCount
        let transcriptionCalls = await provider.transcriptionCallCount
        #expect(statusCalls == 1)
        #expect(transcriptionCalls == 0)
    }

    @Test("Runtime transcription requires an exact code-reviewed profile before touching audio")
    func runtimeRequiresApprovedProfile() async {
        let unapprovedProvider = FakeLocalSpeechAnalyzerProvider(status: .available(fingerprint))
        let unapproved = LocalSpeechAnalyzerQualificationHarness(
            configuration: .init(
                isEnabled: true,
                requiresApprovedProfile: true,
                approvedProfiles: []
            ),
            provider: unapprovedProvider
        )
        let rejected = await unapproved.transcribe(
            wavData: Data([1, 2, 3]),
            languageTag: "en-US",
            isMeeting: false
        )
        #expect(rejected == .skipped(.unqualifiedModel))
        let unapprovedCalls = await unapprovedProvider.transcriptionCallCount
        #expect(unapprovedCalls == 0)

        let profile = SpeechAnalyzerQualificationProfile(
            fingerprint: fingerprint,
            approvedLanguageCodes: ["en", "fr"],
            corpusDigest: "reviewed-corpus-v1",
            approvedAt: Date(timeIntervalSince1970: 2_000_000_000),
            segmentCount: 200,
            actionSignalRecall: 0.99,
            criticalErrorCount: 0
        )
        let approvedProvider = FakeLocalSpeechAnalyzerProvider(status: .available(fingerprint))
        let approved = LocalSpeechAnalyzerQualificationHarness(
            configuration: .init(
                isEnabled: true,
                requiresApprovedProfile: true,
                approvedProfiles: [profile]
            ),
            provider: approvedProvider
        )
        let accepted = await approved.transcribe(
            wavData: Data([1, 2, 3]),
            languageTag: "fr-FR",
            isMeeting: false
        )
        guard case .completed = accepted else {
            Issue.record("Expected the exact approved fingerprint to transcribe locally")
            return
        }
        let approvedCalls = await approvedProvider.transcriptionCallCount
        #expect(approvedCalls == 1)
    }

    @Test("Two hundred balanced FR and EN segments qualify at exactly ninety-nine percent recall")
    func qualificationThreshold() {
        let records = makeCorpus(missedSignalCount: 2)
        let report = SpeechAnalyzerQualificationEvaluator.report(for: records)

        #expect(report.segmentCount == 200)
        #expect(report.segmentCountByLanguage == ["en": 100, "fr": 100])
        #expect(report.referenceActionSignalCount == 200)
        #expect(report.recalledActionSignalCount == 198)
        #expect(abs(report.actionSignalRecall - 0.99) < 0.000_001)
        #expect(report.criticalErrorCount == 0)
        #expect(report.qualifies)
    }

    @Test("Recall below ninety-nine percent, failures, and mixed fingerprints cannot qualify")
    func qualificationFailures() {
        let lowRecall = SpeechAnalyzerQualificationEvaluator.report(
            for: makeCorpus(missedSignalCount: 3)
        )
        var failedCorpus = makeCorpus(missedSignalCount: 0)
        failedCorpus[0].transcriptionSucceeded = false
        let providerFailure = SpeechAnalyzerQualificationEvaluator.report(for: failedCorpus)
        var mixedCorpus = makeCorpus(missedSignalCount: 0)
        mixedCorpus[0].fingerprint.operatingSystemVersion = "different build"
        let mixedFingerprint = SpeechAnalyzerQualificationEvaluator.report(for: mixedCorpus)

        #expect(abs(lowRecall.actionSignalRecall - 0.985) < 0.000_001)
        #expect(!lowRecall.qualifies)
        #expect(providerFailure.criticalErrorCount == 1)
        #expect(!providerFailure.qualifies)
        #expect(mixedFingerprint.mixedFingerprints)
        #expect(!mixedFingerprint.qualifies)
    }

    @Test("A one-language corpus cannot approve the bilingual route")
    func bilingualCoverage() {
        let records = (0..<200).map { _ in
            SpeechAnalyzerQualificationRecord(
                languageCode: "en-US",
                fingerprint: fingerprint,
                referenceSignals: [.explicitNextStep],
                recognizedSignals: [.explicitNextStep]
            )
        }
        let report = SpeechAnalyzerQualificationEvaluator.report(for: records)

        #expect(report.actionSignalRecall == 1)
        #expect(!report.qualifies)
    }

    @Test("Evaluation never promotes a client and the embedded registry starts empty")
    func noAutomaticPromotion() {
        let report = SpeechAnalyzerQualificationEvaluator.report(for: makeCorpus(missedSignalCount: 0))

        #expect(report.qualifies)
        #expect(SpeechAnalyzerQualificationRegistry.embeddedApprovedProfiles.isEmpty)
        #expect(SpeechAnalyzerQualificationRegistry.approvedProfile(
            for: fingerprint,
            languageCode: "en-US"
        ) == nil)
    }

    private var fingerprint: SpeechAnalyzerModelFingerprint {
        SpeechAnalyzerModelFingerprint(
            operatingSystemVersion: "Version 26.5.1 (Build 25F82)",
            speechFrameworkVersion: "1.0 (1)",
            architecture: "arm64",
            harnessVersion: 1
        )
    }

    private func makeCorpus(missedSignalCount: Int) -> [SpeechAnalyzerQualificationRecord] {
        (0..<200).map { index in
            let signal: SpeechAnalyzerActionSignal = index.isMultiple(of: 2) ? .commitment : .deadline
            return SpeechAnalyzerQualificationRecord(
                languageCode: index < 100 ? "en-US" : "fr-FR",
                fingerprint: fingerprint,
                referenceSignals: [signal],
                recognizedSignals: index < missedSignalCount ? [] : [signal]
            )
        }
    }
}

private actor FakeLocalSpeechAnalyzerProvider: LocalSpeechAnalyzerProviding {
    private let providerStatus: LocalSpeechAnalyzerProviderStatus
    private let transcript: String
    private(set) var statusCallCount = 0
    private(set) var transcriptionCallCount = 0

    init(
        status: LocalSpeechAnalyzerProviderStatus,
        transcript: String = "Local transcript"
    ) {
        self.providerStatus = status
        self.transcript = transcript
    }

    func status(for locale: Locale) -> LocalSpeechAnalyzerProviderStatus {
        statusCallCount += 1
        return providerStatus
    }

    func transcribe(wavData: Data, locale: Locale) throws -> String {
        transcriptionCallCount += 1
        return transcript
    }
}

private extension LocalSpeechAnalyzerProviderStatus {
    static func available(_ fingerprint: SpeechAnalyzerModelFingerprint) -> LocalSpeechAnalyzerProviderStatus {
        LocalSpeechAnalyzerProviderStatus(
            availability: .available,
            resolvedLocaleIdentifier: "en-US",
            fingerprint: fingerprint
        )
    }

    static var assetsNotInstalled: LocalSpeechAnalyzerProviderStatus {
        LocalSpeechAnalyzerProviderStatus(
            availability: .assetsNotInstalled,
            resolvedLocaleIdentifier: "fr-FR",
            fingerprint: nil
        )
    }
}
