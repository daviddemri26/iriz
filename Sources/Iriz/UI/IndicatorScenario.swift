import Foundation

struct IndicatorSimulatorSelection: Equatable, Sendable {
    private(set) var hoveredID: String?
    private(set) var focusedID: String?
    private(set) var pinnedID: String?

    var previewID: String? { pinnedID ?? hoveredID ?? focusedID }

    mutating func setHovered(_ id: String, isInside: Bool) {
        if isInside {
            hoveredID = id
        } else if hoveredID == id {
            hoveredID = nil
        }
    }

    mutating func setFocused(_ id: String?) {
        focusedID = id
    }

    mutating func togglePinned(_ id: String) {
        pinnedID = pinnedID == id ? nil : id
    }

    mutating func returnToLive() {
        hoveredID = nil
        focusedID = nil
        pinnedID = nil
    }
}

struct IndicatorScenario: Identifiable, Equatable, Sendable {
    enum Group: String, CaseIterable, Identifiable, Sendable {
        case everyday
        case localActivity
        case openAI
        case outcomesAndAttention

        var id: String { rawValue }

        var title: String {
            switch self {
            case .everyday: "Everyday states"
            case .localActivity: "Local activity"
            case .openAI: "OpenAI activity"
            case .outcomesAndAttention: "Outcomes and attention"
            }
        }
    }

    let id: String
    let title: String
    let detail: String
    let presentation: IndicatorPresentation
    let group: Group
    let modelName: String?

    static let all: [IndicatorScenario] = [
        IndicatorScenario(
            id: "paused",
            title: "Paused",
            detail: "No screen or microphone context is being captured.",
            presentation: .paused,
            group: .everyday,
            modelName: nil
        ),
        IndicatorScenario(
            id: "waiting",
            title: "Waiting",
            detail: "Your selected channels are ready for their scheduled window.",
            presentation: .waiting,
            group: .everyday,
            modelName: nil
        ),
        IndicatorScenario(
            id: "private",
            title: "Private context",
            detail: "Iriz recognized an excluded or protected context and did not capture it.",
            presentation: .privateContext,
            group: .everyday,
            modelName: nil
        ),
        IndicatorScenario(
            id: "private-listening",
            title: "Private + listening",
            detail: "Screen context stays private while the selected microphone channel remains active.",
            presentation: .privateListening,
            group: .everyday,
            modelName: nil
        ),
        IndicatorScenario(
            id: "observing",
            title: "Observing",
            detail: "Selective screen context is active.",
            presentation: .observing,
            group: .everyday,
            modelName: nil
        ),
        IndicatorScenario(
            id: "listening",
            title: "Listening",
            detail: "The selected microphone channel is active.",
            presentation: .listening,
            group: .everyday,
            modelName: nil
        ),
        IndicatorScenario(
            id: "observing-listening",
            title: "Observing + listening",
            detail: "Screen and microphone channels are active together.",
            presentation: .observingAndListening,
            group: .everyday,
            modelName: nil
        ),
        IndicatorScenario(
            id: "meeting",
            title: "Meeting",
            detail: "Iriz detected a supported meeting context.",
            presentation: .meeting,
            group: .everyday,
            modelName: nil
        ),
        IndicatorScenario(
            id: "meeting-listening",
            title: "Meeting + listening",
            detail: "Meeting context and the microphone channel are active together.",
            presentation: .meetingAndListening,
            group: .everyday,
            modelName: nil
        ),
        IndicatorScenario(
            id: "screen-signal",
            title: "Useful screen signal",
            detail: "A meaningful local change passed Iriz's relevance filters.",
            presentation: .screenSignal,
            group: .localActivity,
            modelName: nil
        ),
        IndicatorScenario(
            id: "voice-signal",
            title: "Useful voice signal",
            detail: "A voiced segment passed Iriz's local speech filters.",
            presentation: .voiceSignal,
            group: .localActivity,
            modelName: nil
        ),
        IndicatorScenario(
            id: "routine-api",
            title: "Routine interpretation",
            detail: "Frequent validation or classification is using OpenAI.",
            presentation: .routineAPI,
            group: .openAI,
            modelName: OpenAIModelPolicy.frequentAnalysis
        ),
        IndicatorScenario(
            id: "speech-api",
            title: "Speech processing",
            detail: "Transcription or diarization is using OpenAI.",
            presentation: .speechAPI,
            group: .openAI,
            modelName: "\(OpenAIModelPolicy.transcription) / \(OpenAIModelPolicy.diarizedTranscription)"
        ),
        IndicatorScenario(
            id: "intensive-api",
            title: "Intensive reasoning",
            detail: "Ask Iriz, refinement, or merging is using OpenAI.",
            presentation: .intensiveAPI,
            group: .openAI,
            modelName: OpenAIModelPolicy.consolidation
        ),
        IndicatorScenario(
            id: "saved",
            title: "Follow Up updated",
            detail: "Iriz created or meaningfully enriched a visible Follow Up tile.",
            presentation: .success,
            group: .outcomesAndAttention,
            modelName: nil
        ),
        IndicatorScenario(
            id: "permission",
            title: "Permission needed",
            detail: "A required permission or secure-storage issue needs review.",
            presentation: .permissionNeeded,
            group: .outcomesAndAttention,
            modelName: nil
        ),
        IndicatorScenario(
            id: "blocking-error",
            title: "Iriz needs attention",
            detail: "A persistent fault is preventing observation until it is resolved.",
            presentation: .blockingError,
            group: .outcomesAndAttention,
            modelName: nil
        ),
        IndicatorScenario(
            id: "api-failure",
            title: "API request failed",
            detail: "A request failed once; Iriz returns to its current durable state.",
            presentation: .apiFailure,
            group: .outcomesAndAttention,
            modelName: nil
        )
    ]
}

extension IndicatorPresentation {
    static let paused = CaptureHealth.paused.irizAppearance
    static let waiting = CaptureHealth.waitingForSchedule.irizAppearance
    static let observing = CaptureHealth.observing.irizAppearance
    static let listening = CaptureHealth.listening.irizAppearance
    static let observingAndListening = CaptureHealth.observingAndListening.irizAppearance
    static let meeting = CaptureHealth.meeting.irizAppearance
    static let meetingAndListening = CaptureHealth.meetingAndListening.irizAppearance

    static let privateContext = IndicatorPresentation(
        title: "Private context",
        detail: "This context is excluded and is not captured.",
        symbol: "hand.raised.fill",
        palette: .privateContext,
        badge: "PRIVATE",
        motion: .fixed
    )

    static let privateListening = IndicatorPresentation(
        title: "Private context · listening",
        detail: "Screen context stays private while the microphone remains active.",
        symbol: "hand.raised.fill",
        palette: .privateListening,
        badge: "PRIVATE",
        motion: .fixed
    )

    static let screenSignal = IndicatorPresentation(
        title: "A useful screen signal stood out",
        detail: "A meaningful local change passed the relevance filters.",
        symbol: "sparkles",
        palette: .screenSignal,
        badge: "SIGNAL",
        motion: .fixed
    )

    static let voiceSignal = IndicatorPresentation(
        title: "A useful voice signal stood out",
        detail: "A voiced segment passed the local speech filters.",
        symbol: "waveform.badge.plus",
        palette: .voiceSignal,
        badge: "SIGNAL",
        motion: .fixed
    )

    static let routineAPI = IndicatorPresentation(
        title: "OpenAI · Routine",
        detail: "Running frequent validation or classification.",
        symbol: "sparkles",
        palette: .screenAPI,
        badge: "ROUTINE",
        motion: .api(rotationDuration: 3.2),
        modelName: OpenAIModelPolicy.frequentAnalysis,
        accessibilityActivity: "OpenAI routine request in progress"
    )

    static let speechAPI = IndicatorPresentation(
        title: "OpenAI · Speech",
        detail: "Running transcription or diarization.",
        symbol: "waveform",
        palette: .speechAPI,
        badge: "SPEECH",
        motion: .api(rotationDuration: 1.8),
        modelName: "\(OpenAIModelPolicy.transcription) / \(OpenAIModelPolicy.diarizedTranscription)",
        accessibilityActivity: "OpenAI speech request in progress"
    )

    static let intensiveAPI = IndicatorPresentation(
        title: "OpenAI · Intensive",
        detail: "Running Ask Iriz, refinement, or merging.",
        symbol: "brain.head.profile",
        palette: .intensiveAPI,
        badge: "INTENSIVE",
        motion: .api(rotationDuration: 0.9),
        modelName: OpenAIModelPolicy.consolidation,
        accessibilityActivity: "OpenAI intensive request in progress"
    )

    static let success = IndicatorPresentation(
        title: "Follow Up updated",
        detail: "Iriz created or meaningfully enriched a visible tile.",
        symbol: "checkmark",
        palette: .mint,
        badge: "SAVED",
        motion: .fixed
    )

    static let permissionNeeded = IndicatorPresentation(
        title: "Permission needed",
        detail: "Open Settings to restore observation.",
        symbol: "lock.trianglebadge.exclamationmark.fill",
        palette: .attention,
        badge: "CHECK",
        motion: .fixed
    )

    static let blockingError = IndicatorPresentation(
        title: "Iriz needs attention",
        detail: "A persistent issue is preventing observation. Open Settings to review it.",
        symbol: "exclamationmark.triangle.fill",
        palette: .attention,
        badge: "CHECK",
        motion: .fixed
    )

    static let apiFailure = IndicatorPresentation(
        title: "OpenAI request failed",
        detail: "The request failed once. Iriz will return to its current state.",
        symbol: "exclamationmark.arrow.triangle.2.circlepath",
        palette: .attention,
        badge: "RETRY",
        motion: .fixed
    )
}
