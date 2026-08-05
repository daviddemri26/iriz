import Foundation
import Testing
@testable import Iriz

@available(macOS 26.0, *)
private actor LocalGateProviderStub: LocalGateModelProviding {
    enum StubError: Error {
        case generationFailed
    }

    struct Snapshot: Sendable {
        let environmentCalls: Int
        let prewarmCalls: Int
        let classifyCalls: Int
        let prompts: [String]
    }

    private let environmentValue: LocalGateModelEnvironment
    private var verdicts: [LocalGateVerdict]
    private let shouldThrow: Bool
    private var environmentCalls = 0
    private var prewarmCalls = 0
    private var classifyCalls = 0
    private var prompts: [String] = []

    init(
        environment: LocalGateModelEnvironment,
        verdicts: [LocalGateVerdict] = [.uncertain],
        shouldThrow: Bool = false
    ) {
        self.environmentValue = environment
        self.verdicts = verdicts
        self.shouldThrow = shouldThrow
    }

    func environment(localeIdentifier: String) -> LocalGateModelEnvironment {
        environmentCalls += 1
        return environmentValue
    }

    func prewarm() {
        prewarmCalls += 1
    }

    func classify(prompt: String) throws -> LocalGateVerdict {
        classifyCalls += 1
        prompts.append(prompt)
        if shouldThrow {
            throw StubError.generationFailed
        }
        if verdicts.count > 1 {
            return verdicts.removeFirst()
        }
        return verdicts[0]
    }

    func snapshot() -> Snapshot {
        Snapshot(
            environmentCalls: environmentCalls,
            prewarmCalls: prewarmCalls,
            classifyCalls: classifyCalls,
            prompts: prompts
        )
    }
}

private final class LockedTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

@available(macOS 26.0, *)
@Suite("Apple Foundation Model gate")
struct AppleFoundationModelGateTests {
    @Test("A qualified clearly-empty verdict is the only verdict that suppresses cloud analysis")
    func onlyClearlyEmptySuppressesCloud() async {
        let fingerprint = Self.fingerprint()
        let provider = LocalGateProviderStub(
            environment: .init(availability: .available, fingerprint: fingerprint),
            verdicts: [.clearlyEmpty, .uncertain, .meaningful]
        )
        let gate = AppleFoundationModelGate(
            provider: provider,
            registry: Self.qualifiedRegistry(fingerprint: fingerprint),
            cacheTTL: 0
        )

        let empty = await gate.route(Self.safeInput(text: "Settings appearance preferences panel"), mode: .adaptive)
        let uncertain = await gate.route(Self.safeInput(text: "Draft proposal editing notes and outline"), mode: .adaptive)
        let meaningful = await gate.route(Self.safeInput(text: "Research notes comparing several implementation approaches"), mode: .adaptive)

        #expect(empty.route == .suppressCloud)
        #expect(empty.reason == .clearlyEmpty)
        #expect(uncertain.route == .useCloud)
        #expect(uncertain.reason == .uncertain)
        #expect(meaningful.route == .useCloud)
        #expect(meaningful.reason == .meaningful)
        #expect(await provider.snapshot().classifyCalls == 3)
    }

    @Test("Shadow mode runs the local model but always preserves the cloud call")
    func shadowModeNeverSuppressesCloud() async {
        let fingerprint = Self.fingerprint()
        let provider = LocalGateProviderStub(
            environment: .init(availability: .available, fingerprint: fingerprint),
            verdicts: [.clearlyEmpty]
        )
        let gate = AppleFoundationModelGate(provider: provider, registry: .production)

        let decision = await gate.route(Self.safeInput(), mode: .shadow)

        #expect(decision.route == .useCloud)
        #expect(decision.verdict == .clearlyEmpty)
        #expect(decision.reason == .shadowMode)
        #expect(await provider.snapshot().classifyCalls == 1)
        #expect(await gate.status(languageTag: "en-US", mode: .shadow) == .fallback(.shadowMode))
    }

    @Test("Adaptive mode fails open before inference for an unknown model fingerprint")
    func unknownModelUsesCloud() async {
        let provider = LocalGateProviderStub(
            environment: .init(availability: .available, fingerprint: Self.fingerprint())
        )
        let gate = AppleFoundationModelGate(provider: provider, registry: .production)

        let decision = await gate.route(Self.safeInput(), mode: .adaptive)

        #expect(decision.route == .useCloud)
        #expect(decision.reason == .unqualifiedModel)
        #expect(await provider.snapshot().classifyCalls == 0)
        #expect(await gate.status(languageTag: "en-US", mode: .adaptive) == .fallback(.unqualifiedModel))
    }

    @Test("Availability and locale failures map to explicit fallback states")
    func unavailableModelUsesCloud() async {
        let cases: [(LocalModelAvailability, LocalIntelligenceFallbackReason)] = [
            (.deviceNotEligible, .deviceNotEligible),
            (.appleIntelligenceNotEnabled, .appleIntelligenceNotEnabled),
            (.modelNotReady, .modelNotReady),
            (.unsupportedLocale, .unsupportedLocale),
            (.unsupportedOperatingSystem, .unsupportedOperatingSystem),
            (.unknown, .unavailable)
        ]

        for (availability, fallbackReason) in cases {
            let provider = LocalGateProviderStub(
                environment: .init(availability: availability, fingerprint: Self.fingerprint())
            )
            let gate = AppleFoundationModelGate(provider: provider, registry: .production)

            let decision = await gate.route(Self.safeInput(), mode: .shadow)
            #expect(decision.route == .useCloud)
            #expect(decision.reason == .unavailable(availability))
            #expect(await gate.status(languageTag: "en-US", mode: .shadow) == .fallback(fallbackReason))
            #expect(await provider.snapshot().classifyCalls == 0)
        }
    }

    @Test("Meetings, manual notes, retries, and image-dependent inputs bypass Apple")
    func deterministicSourceBypasses() async {
        let fingerprint = Self.fingerprint()
        let provider = LocalGateProviderStub(
            environment: .init(availability: .available, fingerprint: fingerprint),
            verdicts: [.clearlyEmpty]
        )
        let gate = AppleFoundationModelGate(
            provider: provider,
            registry: Self.qualifiedRegistry(fingerprint: fingerprint)
        )

        let meeting = await gate.route(
            Self.safeInput(source: .meetingMicrophone, isMeeting: true),
            mode: .adaptive
        )
        let manual = await gate.route(Self.safeInput(source: .manualNote), mode: .adaptive)
        let retry = await gate.route(Self.safeInput(isRetry: true), mode: .adaptive)
        let visual = await gate.route(Self.safeInput(requiresVisualContext: true), mode: .adaptive)

        #expect(meeting.reason == .meeting)
        #expect(manual.reason == .manualNote)
        #expect(retry.reason == .retry)
        #expect(visual.reason == .visualContextRequired)
        #expect([meeting, manual, retry, visual].allSatisfy { $0.route == .useCloud })
        #expect(await provider.snapshot().classifyCalls == 0)
    }

    @Test("Commitments, confirmations, transactions, decisions, and dates bypass Apple")
    func highRiskSignalsBypassApple() async {
        let fingerprint = Self.fingerprint()
        let provider = LocalGateProviderStub(
            environment: .init(availability: .available, fingerprint: fingerprint),
            verdicts: [.clearlyEmpty]
        )
        let gate = AppleFoundationModelGate(
            provider: provider,
            registry: Self.qualifiedRegistry(fingerprint: fingerprint)
        )
        let samples = [
            "I will send the revised contract later",
            "Commande confirmée, numéro de commande 4821",
            "Payment receipt for $42.00",
            "We decided to use the second approach",
            "Review planned for Friday afternoon",
            "Échéance fixée au 12/09/2026"
        ]

        for sample in samples {
            let decision = await gate.route(Self.safeInput(text: sample), mode: .adaptive)
            #expect(decision.route == .useCloud)
            #expect(decision.reason == .highRiskSignal)
        }
        #expect(await provider.snapshot().classifyCalls == 0)
    }

    @Test("Sparse OCR fails open instead of trusting the on-device model")
    func sparseOCRUsesCloud() async {
        let fingerprint = Self.fingerprint()
        let provider = LocalGateProviderStub(
            environment: .init(availability: .available, fingerprint: fingerprint),
            verdicts: [.clearlyEmpty]
        )
        let gate = AppleFoundationModelGate(
            provider: provider,
            registry: Self.qualifiedRegistry(fingerprint: fingerprint)
        )

        let decision = await gate.route(Self.safeInput(text: "Continue"), mode: .adaptive)

        #expect(decision.route == .useCloud)
        #expect(decision.reason == .insufficientText)
        #expect(await provider.snapshot().classifyCalls == 0)
    }

    @Test("Any model generation error fails open without exposing the error text")
    func generationErrorUsesCloud() async {
        let fingerprint = Self.fingerprint()
        let provider = LocalGateProviderStub(
            environment: .init(availability: .available, fingerprint: fingerprint),
            shouldThrow: true
        )
        let gate = AppleFoundationModelGate(
            provider: provider,
            registry: Self.qualifiedRegistry(fingerprint: fingerprint)
        )

        let decision = await gate.route(Self.safeInput(), mode: .adaptive)

        #expect(decision.route == .useCloud)
        #expect(decision.reason == .generationFailed)
        #expect(decision.verdict == nil)
    }

    @Test("Verdicts are cached by normalized content and expire after the configured TTL")
    func verdictCache() async {
        let fingerprint = Self.fingerprint()
        let provider = LocalGateProviderStub(
            environment: .init(availability: .available, fingerprint: fingerprint),
            verdicts: [.clearlyEmpty, .meaningful]
        )
        let clock = LockedTestClock(Date(timeIntervalSince1970: 1_000))
        let gate = AppleFoundationModelGate(
            provider: provider,
            registry: Self.qualifiedRegistry(fingerprint: fingerprint),
            cacheTTL: 60,
            now: clock.now
        )

        let first = await gate.route(Self.safeInput(text: "Settings appearance preferences panel"), mode: .adaptive)
        let normalizedDuplicate = await gate.route(Self.safeInput(text: "  SETTINGS   APPEARANCE preferences panel  "), mode: .adaptive)
        clock.advance(by: 61)
        let expired = await gate.route(Self.safeInput(text: "Settings appearance preferences panel"), mode: .adaptive)

        #expect(first.fromCache == false)
        #expect(normalizedDuplicate.fromCache == true)
        #expect(normalizedDuplicate.route == .suppressCloud)
        #expect(expired.fromCache == false)
        #expect(expired.route == .useCloud)
        #expect(expired.verdict == .meaningful)
        #expect(await provider.snapshot().classifyCalls == 2)
    }

    @Test("Prewarming is limited to shadow mode or qualified adaptive models")
    func guardedPrewarm() async {
        let fingerprint = Self.fingerprint()
        let provider = LocalGateProviderStub(
            environment: .init(availability: .available, fingerprint: fingerprint)
        )
        let unknownGate = AppleFoundationModelGate(provider: provider, registry: .production)
        let qualifiedGate = AppleFoundationModelGate(
            provider: provider,
            registry: Self.qualifiedRegistry(fingerprint: fingerprint)
        )

        await unknownGate.prewarm(languageTag: "en-US", mode: .disabled)
        await unknownGate.prewarm(languageTag: "en-US", mode: .adaptive)
        await unknownGate.prewarm(languageTag: "en-US", mode: .shadow)
        await qualifiedGate.prewarm(languageTag: "en-US", mode: .adaptive)

        #expect(await provider.snapshot().prewarmCalls == 2)
    }

    @Test("The local prompt is text-only, bounded, and contains only allowed metadata")
    func textOnlyBoundedPrompt() async {
        let fingerprint = Self.fingerprint()
        let provider = LocalGateProviderStub(
            environment: .init(availability: .available, fingerprint: fingerprint),
            verdicts: [.uncertain]
        )
        let gate = AppleFoundationModelGate(
            provider: provider,
            registry: Self.qualifiedRegistry(fingerprint: fingerprint)
        )
        let longText = String(repeating: "research notes continue ", count: 500)
        let input = LocalGateInput(
            source: .screen,
            applicationName: "Safari",
            windowTitle: "Architecture research",
            host: "example.com",
            text: longText,
            languageTag: "en-US",
            suppliedContentFingerprint: "visual-frame-signature"
        )

        _ = await gate.route(input, mode: .adaptive)
        let prompts = await provider.snapshot().prompts

        #expect(prompts.count == 1)
        #expect(prompts[0].contains("APPLICATION: Safari"))
        #expect(prompts[0].contains("HOST: example.com"))
        #expect(!prompts[0].contains("visual-frame-signature"))
        #expect(prompts[0].count < 6_700)
    }

    @Test("Local event drafts can only materialize conservative observed events")
    func localEventDraftMaterialization() throws {
        let observation = Observation(
            source: .screen,
            applicationName: "Safari",
            url: URL(string: "https://example.com/research"),
            text: "Technical documentation about a rendering architecture"
        )
        let draft = LocalEventDraft(
            kind: .research,
            title: "  Rendering architecture research  ",
            summary: "  Technical documentation was reviewed.  "
        )

        let event = try draft.makeActivityEvent(
            from: observation,
            languageTag: "en-US",
            confidence: 0.95
        )

        #expect(event.kind == .research)
        #expect(event.status == .observed)
        #expect(event.importance == .normal)
        #expect(event.title == "Rendering architecture research")
        #expect(event.summary == "Technical documentation was reviewed.")
        #expect(event.confidence == 0.70)
        #expect(event.evidence.map(\.observationID) == [observation.id])
    }

    @Test("Local event drafts reject empty, oversized, temporal, transactional, and completion claims")
    func localEventDraftValidation() {
        let cases: [(LocalEventDraft, LocalEventDraftValidationError)] = [
            (.init(kind: .note, title: "", summary: "A neutral note."), .emptyTitle),
            (.init(kind: .note, title: "Neutral note", summary: ""), .emptySummary),
            (.init(kind: .note, title: String(repeating: "a", count: 81), summary: "Neutral."), .titleTooLong),
            (.init(kind: .note, title: "Neutral note", summary: String(repeating: "a", count: 241)), .summaryTooLong),
            (.init(kind: .note, title: "Task completed", summary: "The work is done."), .highRiskContent),
            (.init(kind: .research, title: "Friday review", summary: "Research notes were reviewed."), .highRiskContent),
            (.init(kind: .document, title: "Invoice document", summary: "A $42 receipt was visible."), .highRiskContent)
        ]

        for (draft, expectedError) in cases {
            do {
                _ = try draft.validated()
                Issue.record("Expected validation to reject \(draft)")
            } catch let error as LocalEventDraftValidationError {
                #expect(error == expectedError)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test("Qualification registry matching is exact across OS and prompt versions")
    func exactQualificationMatching() {
        let qualified = Self.fingerprint()
        let profile = AppleQualificationProfile(
            fingerprint: qualified,
            gateEnabled: true,
            localEventDraftEnabled: false,
            qualifiedAt: Date(timeIntervalSince1970: 1_000)
        )
        let registry = AppleQualificationRegistry(profiles: [profile])
        let newOSVersion = AppleModelFingerprint(
            operatingSystemMajor: qualified.operatingSystemMajor,
            operatingSystemMinor: qualified.operatingSystemMinor + 1,
            localeIdentifier: qualified.localeIdentifier,
            promptVersion: qualified.promptVersion,
            schemaVersion: qualified.schemaVersion
        )
        let newPromptVersion = AppleModelFingerprint(
            operatingSystemMajor: qualified.operatingSystemMajor,
            operatingSystemMinor: qualified.operatingSystemMinor,
            localeIdentifier: qualified.localeIdentifier,
            promptVersion: "local-gate-v2",
            schemaVersion: qualified.schemaVersion
        )

        #expect(registry.profile(for: qualified) == profile)
        #expect(registry.profile(for: newOSVersion) == nil)
        #expect(registry.profile(for: newPromptVersion) == nil)
        #expect(AppleQualificationRegistry.production.profile(for: qualified) == nil)
    }

    private static func fingerprint() -> AppleModelFingerprint {
        AppleModelFingerprint(
            operatingSystemMajor: 26,
            operatingSystemMinor: 5,
            localeIdentifier: "en-US",
            promptVersion: SystemFoundationModelGateProvider.promptVersion,
            schemaVersion: SystemFoundationModelGateProvider.schemaVersion
        )
    }

    private static func qualifiedRegistry(fingerprint: AppleModelFingerprint) -> AppleQualificationRegistry {
        AppleQualificationRegistry(
            profiles: [
                AppleQualificationProfile(
                    fingerprint: fingerprint,
                    gateEnabled: true,
                    localEventDraftEnabled: false,
                    qualifiedAt: Date(timeIntervalSince1970: 1_000)
                )
            ]
        )
    }

    private static func safeInput(
        source: ObservationSource = .screen,
        text: String = "Settings appearance preferences panel",
        isMeeting: Bool = false,
        isRetry: Bool = false,
        requiresVisualContext: Bool = false
    ) -> LocalGateInput {
        LocalGateInput(
            source: source,
            applicationName: "System Settings",
            windowTitle: "Appearance preferences",
            host: nil,
            text: text,
            languageTag: "en-US",
            isMeeting: isMeeting,
            isRetry: isRetry,
            requiresVisualContext: requiresVisualContext
        )
    }
}
