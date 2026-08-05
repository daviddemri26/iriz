import Foundation

enum IndicatorPresentationResolver {
    static func resolve(
        captureHealth: CaptureHealth,
        snapshot: IndicatorActivitySnapshot
    ) -> IndicatorPresentation {
        let background = backgroundPresentation(
            captureHealth: captureHealth,
            snapshot: snapshot
        )

        if let activity = snapshot.dominantAPIActivity {
            return apiPresentation(for: activity.descriptor)
        }

        switch captureHealth {
        case .permissionNeeded, .error:
            return captureHealth.irizAppearance
        case .paused, .observing, .listening, .observingAndListening,
             .waitingForSchedule, .meeting, .meetingAndListening, .processing:
            break
        }

        if case .apiFailure(let context, let occurredAt)? = snapshot.transientEvent {
            return failurePresentation(for: context, occurredAt: occurredAt)
        }

        if case .success(let context, let occurredAt)? = snapshot.transientEvent {
            return successPresentation(for: context, occurredAt: occurredAt)
        }

        if let activity = snapshot.dominantLocalActivity {
            return localPresentation(
                for: activity.descriptor.context,
                activeContexts: snapshot.localActivities.map(\.descriptor.context),
                concurrentPalette: background.palette
            )
        }

        return background
    }

    private static func backgroundPresentation(
        captureHealth: CaptureHealth,
        snapshot: IndicatorActivitySnapshot
    ) -> IndicatorPresentation {
        if snapshot.screenVisibility == .private {
            return microphoneIsActive(in: captureHealth) ? .privateListening : .privateContext
        }
        return captureHealth.irizAppearance
    }

    private static func microphoneIsActive(in captureHealth: CaptureHealth) -> Bool {
        switch captureHealth {
        case .listening, .observingAndListening, .meetingAndListening:
            true
        case .paused, .observing, .waitingForSchedule, .meeting, .processing,
             .permissionNeeded, .error:
            false
        }
    }

    private static func localPresentation(
        for context: IndicatorActivityContext,
        activeContexts: [IndicatorActivityContext],
        concurrentPalette: IndicatorPalette
    ) -> IndicatorPresentation {
        let presentation: IndicatorPresentation = switch context {
        case .screen:
            .screenSignal
        case .voice:
            .voiceSignal
        case .meeting:
            IndicatorPresentation(
                title: "A useful meeting signal stood out",
                detail: "Meaningful meeting context passed the local filters.",
                symbol: "person.2.fill",
                palette: .meetingSignal,
                badge: "SIGNAL",
                motion: .fixed
            )
        case .assistant:
            IndicatorPresentation(
                title: "Preparing Ask Iriz",
                detail: "Iriz is assembling relevant local memory.",
                symbol: "sparkles",
                palette: .violetSignal,
                badge: "LOCAL",
                motion: .fixed
            )
        case .followUp:
            IndicatorPresentation(
                title: "Preparing Follow Up",
                detail: "Iriz is connecting relevant local context.",
                symbol: "checklist",
                palette: .violetSignal,
                badge: "LOCAL",
                motion: .fixed
            )
        case .credentials:
            IndicatorPresentation(
                title: "Checking credentials locally",
                detail: "Iriz is preparing a secure credential check.",
                symbol: "key.fill",
                palette: .violetSignal,
                badge: "LOCAL",
                motion: .fixed
            )
        }

        let activeContextSet = Set(activeContexts)
        let activityPalette = localContextOrder
            .filter(activeContextSet.contains)
            .reduce(IndicatorPalette([])) { palette, context in
            palette.merging(context.localSignalPalette)
        }
        return presentation.withPalette(
            meaningfulConcurrentPalette(concurrentPalette).merging(activityPalette)
        )
    }

    private static func apiPresentation(
        for descriptor: IndicatorAPIActivityDescriptor
    ) -> IndicatorPresentation {
        IndicatorPresentation(
            title: "OpenAI · \(descriptor.level.displayName)",
            detail: descriptor.task.indicatorDetail,
            symbol: descriptor.context.indicatorSymbol,
            palette: descriptor.context.apiPalette,
            badge: descriptor.level.displayName.uppercased(),
            motion: .api(rotationDuration: descriptor.level.rotationDuration),
            modelName: descriptor.model,
            accessibilityActivity: "OpenAI \(descriptor.level.displayName.lowercased()) request for \(descriptor.task.accessibilityName) in progress"
        )
    }

    private static func successPresentation(
        for context: IndicatorActivityContext,
        occurredAt _: Date
    ) -> IndicatorPresentation {
        IndicatorPresentation(
            title: "Follow Up updated",
            detail: context == .followUp
                ? "Iriz created or meaningfully enriched a visible tile."
                : "Iriz saved a useful result to Follow Up.",
            symbol: "checkmark",
            palette: .mint,
            badge: "SAVED",
            motion: .fixed
        )
    }

    private static func failurePresentation(
        for context: IndicatorActivityContext,
        occurredAt _: Date
    ) -> IndicatorPresentation {
        IndicatorPresentation(
            title: "OpenAI request failed",
            detail: "The \(context.failureContextName) request failed once. Iriz is returning to its current state.",
            symbol: "exclamationmark.arrow.triangle.2.circlepath",
            palette: .attention,
            badge: "RETRY",
            motion: .fixed
        )
    }

    private static func meaningfulConcurrentPalette(
        _ palette: IndicatorPalette
    ) -> IndicatorPalette {
        let tokens = palette.tokens.filter { $0 != .neutral && $0 != .attention }
        return IndicatorPalette(tokens)
    }

    private static let localContextOrder: [IndicatorActivityContext] = [
        .screen, .meeting, .voice, .assistant, .followUp, .credentials
    ]
}

@MainActor
extension AppState {
    var indicatorPresentation: IndicatorPresentation {
        IndicatorPresentationResolver.resolve(
            captureHealth: captureHealth,
            snapshot: indicatorSnapshot
        )
    }
}

private extension IndicatorPresentation {
    func withPalette(_ palette: IndicatorPalette) -> IndicatorPresentation {
        IndicatorPresentation(
            title: title,
            detail: detail,
            symbol: symbol,
            palette: palette,
            badge: badge,
            motion: motion,
            modelName: modelName,
            accessibilityActivity: accessibilityActivity
        )
    }
}

private extension IndicatorActivityContext {
    var localSignalPalette: IndicatorPalette {
        switch self {
        case .screen: .screenSignal
        case .voice: .voiceSignal
        case .meeting: .meetingSignal
        case .assistant, .followUp, .credentials: .violetSignal
        }
    }

    var apiPalette: IndicatorPalette {
        switch self {
        case .screen: .screenAPI
        case .voice: .speechAPI
        case .meeting: .meetingAPI
        case .assistant, .followUp, .credentials: .intensiveAPI
        }
    }

    var indicatorSymbol: String {
        switch self {
        case .screen: "eye.fill"
        case .voice: "waveform"
        case .meeting: "person.2.fill"
        case .assistant: "sparkles"
        case .followUp: "checklist"
        case .credentials: "key.fill"
        }
    }

    var failureContextName: String {
        switch self {
        case .screen: "screen interpretation"
        case .voice: "speech"
        case .meeting: "meeting interpretation"
        case .assistant: "Ask Iriz"
        case .followUp: "Follow Up"
        case .credentials: "credential validation"
        }
    }
}

private extension IndicatorAPITask {
    var indicatorDetail: String {
        switch self {
        case .credentialValidation: "Validating your API key."
        case .observationClassification: "Interpreting selected screen or text context."
        case .originalImageAnalysis: "Reviewing a selected key image."
        case .transcription: "Transcribing a selected voice segment."
        case .diarizedTranscription: "Separating speakers in a selected meeting segment."
        case .assistantAnswer: "Answering from relevant Iriz memory."
        case .eventRefinement: "Refining useful evidence into structured memory."
        case .followUpMerge: "Resolving related Follow Up items."
        }
    }

    var accessibilityName: String {
        switch self {
        case .credentialValidation: "credential validation"
        case .observationClassification: "context classification"
        case .originalImageAnalysis: "key image analysis"
        case .transcription: "transcription"
        case .diarizedTranscription: "speaker diarization"
        case .assistantAnswer: "Ask Iriz"
        case .eventRefinement: "memory refinement"
        case .followUpMerge: "Follow Up merging"
        }
    }
}
