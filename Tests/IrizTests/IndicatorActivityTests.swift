import Foundation
import Testing
@testable import Iriz

@Suite("Indicator activity")
struct IndicatorActivityTests {
    @MainActor
    @Test("API levels expose the documented relative cadence and model")
    func apiLevelMetadata() {
        let routine = OpenAIModelPolicy.configuration(for: .observationClassification)
        let intensive = OpenAIModelPolicy.configuration(for: .eventConsolidation)
        let speech = OpenAIModelPolicy.transcriptionDescriptor(diarize: false, context: .voice)
        let diarized = OpenAIModelPolicy.transcriptionDescriptor(diarize: true, context: .meeting)

        #expect(routine.model == OpenAIModelPolicy.frequentAnalysis)
        #expect(routine.activityLevel == .routine)
        #expect(intensive.model == OpenAIModelPolicy.consolidation)
        #expect(intensive.activityLevel == .intensive)
        #expect(speech.model == OpenAIModelPolicy.transcription)
        #expect(speech.level == .speech)
        #expect(diarized.model == OpenAIModelPolicy.diarizedTranscription)
        #expect(diarized.level == .speech)
        #expect(IndicatorAPILevel.routine.rotationDuration == 3.2)
        #expect(IndicatorAPILevel.speech.rotationDuration == 1.8)
        #expect(IndicatorAPILevel.intensive.rotationDuration == 0.9)
    }

    @MainActor
    @Test("Every OpenAI task maps to its documented model and visual level")
    func everyOpenAITaskMapping() {
        let routine: [OpenAITask] = [.credentialValidation, .observationClassification]
        let intensive: [OpenAITask] = [
            .eventConsolidation,
            .followUpMerge,
            .assistantAnswer,
            .complexAssistantAnswer
        ]

        for task in routine {
            let configuration = OpenAIModelPolicy.configuration(for: task)
            #expect(configuration.model == OpenAIModelPolicy.frequentAnalysis)
            #expect(configuration.activityLevel == .routine)
        }
        for task in intensive {
            let configuration = OpenAIModelPolicy.configuration(for: task)
            #expect(configuration.model == OpenAIModelPolicy.consolidation)
            #expect(configuration.activityLevel == .intensive)
        }
    }

    @MainActor
    @Test("OpenAI transport starts and finishes its real activity token on success")
    func openAITransportSuccess() async throws {
        let store = IndicatorActivityStore()
        let gate = OpenAIRequestGate()
        let client = OpenAIClient(
            baseURL: URL(string: "https://indicator.test/v1")!,
            indicatorActivities: store,
            dataLoader: { request in try await gate.load(request) }
        )

        let request = Task { try await client.validateAPIKey("sk-test") }
        await gate.waitUntilStarted()
        #expect(store.snapshot.apiActivities.count == 1)
        #expect(store.snapshot.dominantAPIActivity?.descriptor.task == .credentialValidation)
        await gate.release()
        try await request.value

        #expect(store.snapshot.apiActivities.isEmpty)
        #expect(store.snapshot.transientEvent == nil)
    }

    @MainActor
    @Test("OpenAI transport ends on HTTP failure and emits one orange outcome")
    func openAITransportFailure() async {
        let store = IndicatorActivityStore()
        let client = OpenAIClient(
            baseURL: URL(string: "https://indicator.test/v1")!,
            indicatorActivities: store,
            dataLoader: { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data("{\"error\":{\"message\":\"temporary\"}}".utf8), response)
            }
        )

        do {
            try await client.validateAPIKey("sk-test")
            Issue.record("Expected the HTTP failure to escape the transport")
        } catch {
            #expect(error is OpenAIClientError)
        }
        #expect(store.snapshot.apiActivities.isEmpty)
        guard case .apiFailure(let context, _)? = store.snapshot.transientEvent else {
            Issue.record("Expected one transient API failure")
            return
        }
        #expect(context == .credentials)
        store.clearTransientEvent()
    }

    @MainActor
    @Test("OpenAI transport cancellation removes its token without an error highlight")
    func openAITransportCancellation() async {
        let store = IndicatorActivityStore()
        let probe = OpenAIRequestStartProbe()
        let client = OpenAIClient(
            baseURL: URL(string: "https://indicator.test/v1")!,
            indicatorActivities: store,
            dataLoader: { request in
                await probe.markStarted()
                try await Task.sleep(for: .seconds(30))
                return (
                    Data(),
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )

        let request = Task { try await client.validateAPIKey("sk-test") }
        await probe.waitUntilStarted()
        #expect(store.snapshot.apiActivities.count == 1)
        request.cancel()
        do {
            try await request.value
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(store.snapshot.apiActivities.isEmpty)
        #expect(store.snapshot.transientEvent == nil)
    }

    @MainActor
    @Test("Overlapping API tokens remain active and resolve deterministically")
    func overlappingAPITokens() {
        let store = IndicatorActivityStore()
        let now = Date()
        let routineToken = store.beginAPI(IndicatorAPIActivityDescriptor(
            task: .observationClassification,
            model: OpenAIModelPolicy.frequentAnalysis,
            level: .routine,
            context: .screen,
            startedAt: now.addingTimeInterval(10)
        ))
        let intensiveToken = store.beginAPI(IndicatorAPIActivityDescriptor(
            task: .assistantAnswer,
            model: OpenAIModelPolicy.consolidation,
            level: .intensive,
            context: .assistant,
            startedAt: now
        ))

        #expect(store.snapshot.apiActivities.count == 2)
        #expect(store.snapshot.dominantAPIActivity?.id == intensiveToken)
        #expect(store.finishAPI(routineToken, completion: .success))
        #expect(store.snapshot.dominantAPIActivity?.id == intensiveToken)
        #expect(!store.finishAPI(routineToken, completion: .success))
        #expect(store.finishAPI(intensiveToken, completion: .success))
        #expect(store.snapshot.apiActivities.isEmpty)
    }

    @MainActor
    @Test("Newest request breaks ties and token completion cannot stop a peer")
    func apiTieBreakAndOutOfOrderCompletion() {
        let store = IndicatorActivityStore()
        let now = Date()
        let older = store.beginAPI(IndicatorAPIActivityDescriptor(
            task: .followUpMerge,
            model: OpenAIModelPolicy.consolidation,
            level: .intensive,
            context: .followUp,
            startedAt: now
        ))
        let newer = store.beginAPI(IndicatorAPIActivityDescriptor(
            task: .eventRefinement,
            model: OpenAIModelPolicy.consolidation,
            level: .intensive,
            context: .followUp,
            startedAt: now.addingTimeInterval(1)
        ))

        #expect(store.snapshot.dominantAPIActivity?.id == newer)
        #expect(store.finishAPI(newer, completion: .cancelled))
        #expect(store.snapshot.dominantAPIActivity?.id == older)
        #expect(store.finishAPI(older, completion: .success))
        #expect(store.snapshot.apiActivities.isEmpty)
    }

    @MainActor
    @Test("Only API failure emits a transient orange event")
    func apiCompletionOutcomes() {
        let store = IndicatorActivityStore()
        let failed = store.beginAPI(IndicatorAPIActivityDescriptor(
            task: .transcription,
            model: OpenAIModelPolicy.transcription,
            level: .speech,
            context: .voice
        ))
        let cancelled = store.beginAPI(IndicatorAPIActivityDescriptor(
            task: .observationClassification,
            model: OpenAIModelPolicy.frequentAnalysis,
            level: .routine,
            context: .screen
        ))

        #expect(store.finishAPI(failed, completion: .failure))
        #expect(store.snapshot.transientEvent == nil)
        #expect(store.finishAPI(cancelled, completion: .cancelled))
        guard case .apiFailure(let context, _)? = store.snapshot.transientEvent else {
            Issue.record("Expected a transient API failure")
            return
        }
        #expect(context == .voice)
        guard case .apiFailure(let retainedContext, _)? = store.snapshot.transientEvent else {
            Issue.record("Cancellation replaced the failure event")
            return
        }
        #expect(retainedContext == .voice)
        store.clearTransientEvent()
        #expect(store.snapshot.transientEvent == nil)
    }

    @MainActor
    @Test("Duplicate failures coalesce and a success cannot replace an active failure")
    func failureCoalescingAndPriority() {
        let store = IndicatorActivityStore()
        let now = Date()
        store.emitAPIFailure(context: .screen, at: now)
        let first = store.snapshot.transientEvent

        store.emitAPIFailure(context: .voice, at: now.addingTimeInterval(0.2))
        #expect(store.snapshot.transientEvent == first)

        store.emitSuccess(context: .followUp, at: now.addingTimeInterval(0.4))
        #expect(store.snapshot.transientEvent == first)
        store.clearTransientEvent()
    }

    @MainActor
    @Test("Transient outcome waits until the final overlapping API request finishes")
    func deferredOutcomeUntilLastAPI() {
        let store = IndicatorActivityStore()
        let first = store.beginAPI(IndicatorAPIActivityDescriptor(
            task: .assistantAnswer,
            model: OpenAIModelPolicy.consolidation,
            level: .intensive,
            context: .assistant
        ))
        let second = store.beginAPI(IndicatorAPIActivityDescriptor(
            task: .observationClassification,
            model: OpenAIModelPolicy.frequentAnalysis,
            level: .routine,
            context: .screen
        ))

        store.emitSuccess(context: .followUp)
        #expect(store.snapshot.transientEvent == nil)
        #expect(store.finishAPI(first, completion: .success))
        #expect(store.snapshot.transientEvent == nil)
        #expect(store.snapshot.apiActivities.count == 1)

        #expect(store.finishAPI(second, completion: .success))
        #expect(store.snapshot.apiActivities.isEmpty)
        guard case .success(let context, _)? = store.snapshot.transientEvent else {
            Issue.record("Expected the queued outcome after the last API request")
            return
        }
        #expect(context == .followUp)
        store.clearTransientEvent()
    }

    @MainActor
    @Test("Mint success coalesces simultaneous visible Follow Up changes")
    func successCoalescing() {
        let store = IndicatorActivityStore()
        let now = Date()
        store.emitSuccess(context: .followUp, at: now)
        let first = store.snapshot.transientEvent
        store.emitSuccess(context: .followUp, at: now.addingTimeInterval(0.2))
        #expect(store.snapshot.transientEvent == first)
        store.clearTransientEvent()
    }

    @Test("Outcome policy accepts only AI-created or visibly enriched tiles")
    func followUpOutcomePolicy() {
        let original = commitment(origin: .iriz)
        #expect(FollowUpIndicatorOutcomePolicy.shouldHighlight(previous: nil, updated: original, source: .iriz))
        #expect(!FollowUpIndicatorOutcomePolicy.shouldHighlight(
            previous: nil,
            updated: commitment(origin: .manual),
            source: .iriz
        ))

        var metadataOnly = original
        metadataOnly.updatedAt = original.updatedAt.addingTimeInterval(10)
        metadataOnly.confidence = 0.99
        #expect(!FollowUpIndicatorOutcomePolicy.shouldHighlight(previous: original, updated: metadataOnly, source: .iriz))

        var enriched = metadataOnly
        enriched.details = "The signed proposal is attached."
        #expect(FollowUpIndicatorOutcomePolicy.shouldHighlight(previous: original, updated: enriched, source: .iriz))
        #expect(!FollowUpIndicatorOutcomePolicy.shouldHighlight(previous: original, updated: enriched, source: .manual))
        #expect(!FollowUpIndicatorOutcomePolicy.shouldHighlight(previous: original, updated: enriched, source: .rawObservation))
    }

    @Test("Private context carries no capturable metadata")
    func privateContextOutcome() {
        let privateOutcome = ActiveContextOutcome.private
        #expect(privateOutcome.visibility == .private)
        #expect(privateOutcome.capturableContext == nil)

        let context = ActiveContext(
            applicationName: "Browser",
            bundleIdentifier: "com.example.browser",
            windowTitle: "Non-sensitive title",
            url: URL(string: "https://example.com"),
            isMeeting: false
        )
        let available = ActiveContextOutcome.available(context)
        #expect(available.visibility == .available)
        #expect(available.capturableContext == context)
    }

    @Test("Durable capture health preserves meetings, blockers and recovery")
    func durableCaptureHealth() {
        var settings = IrizSettings()
        settings.isPaused = false
        settings.screenCaptureEnabled = true
        settings.audioMode = .alwaysOn
        settings.captureTiming = .alwaysOn
        settings.meetingDetectionEnabled = true

        var input = CaptureHealthInputs(
            settings: settings,
            secureStorageState: .ready,
            apiKeyState: .valid,
            screenPermission: .granted,
            accessibilityPermission: .granted,
            microphonePermission: .granted,
            screenFailureMessage: nil,
            audioFailureMessage: nil,
            screenVisibility: .available,
            meetingContextDetected: true,
            now: Date()
        )
        #expect(CaptureHealthResolver.resolve(input) == .meetingAndListening)

        input.settings.audioMode = .off
        #expect(CaptureHealthResolver.resolve(input) == .meeting)
        input.settings.audioMode = .alwaysOn

        input.screenVisibility = .private
        #expect(CaptureHealthResolver.resolve(input) == .observingAndListening)

        input.apiKeyState = .invalid("Unauthorized")
        input.settings.isPaused = true
        #expect(CaptureHealthResolver.resolve(input) == .error("OpenAI credentials need attention."))

        input.apiKeyState = .valid
        input.settings.isPaused = false
        input.screenVisibility = .available
        input.meetingContextDetected = false
        input.accessibilityPermission = .denied
        #expect(CaptureHealthResolver.resolve(input) == .permissionNeeded("Accessibility"))

        input.accessibilityPermission = .granted
        input.screenFailureMessage = "Screen observation is unavailable."
        #expect(CaptureHealthResolver.resolve(input) == .error("Screen observation is unavailable."))
        input.screenFailureMessage = nil
        #expect(CaptureHealthResolver.resolve(input) == .observingAndListening)
    }

    private func commitment(origin: FollowUpOrigin) -> Commitment {
        Commitment(
            eventID: UUID(),
            owner: "You",
            action: "Send the client proposal",
            rationale: "Explicit commitment in the conversation",
            contextLabel: "Northstar",
            confidence: 0.85,
            state: .needsAttention,
            summary: "Prepare and send the approved proposal.",
            origin: origin
        )
    }
}

private actor OpenAIRequestGate {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        started = true
        await withCheckedContinuation { continuation = $0 }
        try Task.checkCancellation()
        return (
            Data(),
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor OpenAIRequestStartProbe {
    private var started = false

    func markStarted() {
        started = true
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }
}
