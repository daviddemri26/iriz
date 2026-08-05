import Foundation
import Testing
@testable import Iriz

@Suite("Indicator presentation")
struct IndicatorPresentationTests {
    @Test("Durable states use the planned background language")
    func durableStates() {
        let snapshot = IndicatorActivitySnapshot(screenVisibility: .available)

        #expect(resolve(.paused, snapshot).palette == .neutral)
        #expect(resolve(.paused, snapshot).motion == .fixed)
        #expect(resolve(.waitingForSchedule, snapshot).palette == .neutral)
        #expect(resolve(.observing, snapshot).palette == .observing)
        #expect(resolve(.observing, snapshot).motion == .fixed)
        #expect(resolve(.listening, snapshot).palette == .listening)
        #expect(resolve(.observingAndListening, snapshot).palette == .observingAndListening)
        #expect(resolve(.observingAndListening, snapshot).palette.tokens == [.observing, .listening])
        #expect(resolve(.meeting, snapshot).palette == .meeting)
        #expect(resolve(.meeting, snapshot).palette.tokens == [.observing, .meeting])
        #expect(resolve(.meetingAndListening, snapshot).palette == .meetingAndListening)
        #expect(resolve(.meetingAndListening, snapshot).palette.tokens == [.observing, .meeting, .listening])
        #expect(resolve(.permissionNeeded("Screen Recording"), snapshot).palette == .attention)
        #expect(resolve(.permissionNeeded("Screen Recording"), snapshot).motion == .fixed)
        #expect(resolve(.error("Unavailable"), snapshot).palette == .attention)
    }

    @Test("Private screen context never exposes sensitive source details")
    func privateContext() {
        let snapshot = IndicatorActivitySnapshot(screenVisibility: .private)
        let privateOnly = resolve(.observing, snapshot)
        let privateListening = resolve(.observingAndListening, snapshot)

        #expect(privateOnly.palette == .privateContext)
        #expect(privateOnly.motion == .fixed)
        #expect(privateOnly.detail == "This context is excluded and is not captured.")
        #expect(privateListening.palette == .privateListening)
        #expect(privateListening.palette.tokens == [.privateContext, .listening])
        #expect(privateListening.motion == .fixed)
        #expect(!privateOnly.detail.localizedCaseInsensitiveContains("app"))
        #expect(!privateOnly.detail.localizedCaseInsensitiveContains("domain"))
    }

    @Test("API activity wins over every other presentation layer")
    func apiPriority() {
        let now = Date()
        let snapshot = IndicatorActivitySnapshot(
            screenVisibility: .private,
            localActivities: [local(.screen, at: now.addingTimeInterval(-1))],
            apiActivities: [api(.routine, context: .screen, at: now)],
            transientEvent: .apiFailure(context: .voice, occurredAt: now)
        )

        let presentation = resolve(.error("Persistent issue"), snapshot)
        #expect(presentation.badge == "ROUTINE")
        #expect(presentation.palette == .screenAPI)
        #expect(presentation.modelName == OpenAIModelPolicy.frequentAnalysis)
    }

    @Test("Failure, blocker, success, local signal and background use deterministic priority")
    func remainingPriority() {
        let now = Date()
        let localActivity = local(.voice, at: now)

        let failed = IndicatorActivitySnapshot(
            screenVisibility: .available,
            localActivities: [localActivity],
            transientEvent: .apiFailure(context: .voice, occurredAt: now)
        )
        #expect(resolve(.observing, failed).title == "OpenAI request failed")
        #expect(resolve(.error("Persistent issue"), failed).badge == "CHECK")

        let blockedWithSuccess = IndicatorActivitySnapshot(
            screenVisibility: .available,
            localActivities: [localActivity],
            transientEvent: .success(context: .followUp, occurredAt: now)
        )
        #expect(resolve(.permissionNeeded("Microphone"), blockedWithSuccess).badge == "CHECK")

        #expect(resolve(.observing, blockedWithSuccess).palette == .mint)

        let localOnly = IndicatorActivitySnapshot(
            screenVisibility: .available,
            localActivities: [localActivity]
        )
        #expect(resolve(.observing, localOnly).palette.tokens == [.observing, .listening, .voiceSignalHighlight])

        #expect(resolve(.observing, IndicatorActivitySnapshot(screenVisibility: .available)).palette == .observing)
    }

    @Test("Concurrent local states compose every color in a stable order")
    func concurrentLocalColors() {
        let now = Date()
        let screen = local(.screen, at: now)
        let voice = local(.voice, at: now.addingTimeInterval(1))
        let forward = IndicatorActivitySnapshot(
            screenVisibility: .available,
            localActivities: [screen, voice]
        )
        let reversed = IndicatorActivitySnapshot(
            screenVisibility: .available,
            localActivities: [voice, screen]
        )

        let expected: [IndicatorColorToken] = [
            .observing, .listening, .apiHighlight, .voiceSignalHighlight
        ]
        #expect(resolve(.observingAndListening, forward).palette.tokens == expected)
        #expect(resolve(.observingAndListening, reversed).palette.tokens == expected)
    }

    @Test("API levels carry their exact cadence and model")
    func apiCadence() {
        let now = Date()
        let cases: [(IndicatorAPILevel, TimeInterval, IndicatorActivityContext, IndicatorPalette, String)] = [
            (.routine, 3.2, .screen, .screenAPI, OpenAIModelPolicy.frequentAnalysis),
            (.speech, 1.8, .voice, .speechAPI, OpenAIModelPolicy.transcription),
            (.intensive, 0.9, .assistant, .intensiveAPI, OpenAIModelPolicy.consolidation)
        ]

        for (level, duration, context, palette, model) in cases {
            let presentation = resolve(
                .observing,
                IndicatorActivitySnapshot(
                    screenVisibility: .available,
                    apiActivities: [api(level, context: context, model: model, at: now)]
                )
            )
            #expect(presentation.palette == palette)
            #expect(presentation.modelName == model)
            guard case .api(let resolvedDuration) = presentation.motion else {
                Issue.record("Expected API motion for \(level.displayName)")
                continue
            }
            #expect(resolvedDuration == duration)
            #expect(presentation.accessibilityLabel.contains(model))
        }
    }

    @Test("Transient outcomes change color without changing border geometry")
    func fixedOutcomes() {
        let date = Date(timeIntervalSinceReferenceDate: 42)
        let success = resolve(
            .observing,
            IndicatorActivitySnapshot(
                screenVisibility: .available,
                transientEvent: .success(context: .followUp, occurredAt: date)
            )
        )
        let failure = resolve(
            .observing,
            IndicatorActivitySnapshot(
                screenVisibility: .available,
                transientEvent: .apiFailure(context: .screen, occurredAt: date)
            )
        )

        #expect(success.motion == .fixed)
        #expect(success.palette == .mint)
        #expect(failure.motion == .fixed)
        #expect(failure.palette == .attention)
    }

    @Test("The production geometry overlaps a fixed border onto the 46 point logo")
    func geometry() {
        #expect(IrizIndicatorMetrics.logoSize == 46)
        #expect(IrizIndicatorMetrics.logoContentScale == 1.20)
        #expect(IrizIndicatorMetrics.ringWidth == 4)
        #expect(IrizIndicatorMetrics.ringOverlap == 2)
        #expect(IrizIndicatorMetrics.ringOutset == 2)
        #expect(IrizIndicatorMetrics.canvasSize(for: 46) == 50)
        #expect(IrizIndicatorMetrics.collapsedPanelSize == 60)
        #expect(ObservationControlMetrics.cardWidth == 276)
        #expect(ObservationControlMetrics.floatingWidth == 282)
        #expect(ObservationControlMetrics.cardHeight == 313)
        #expect(ObservationControlMetrics.floatingHeight == 335)
    }

    @Test("Permission status routes directly to Privacy")
    func permissionSettingsDestination() {
        #expect(IndicatorSettingsDestination.category(
            for: .permissionNeeded("Screen Recording")
        ) == .privacy)
        #expect(IndicatorSettingsDestination.category(for: .observing) == nil)
        #expect(IndicatorSettingsDestination.category(for: .error("Network")) == nil)
        #expect(SettingsCategory.allCases.map(\.rawValue) == [
            "Capture", "AI & Language", "Memory", "Privacy"
        ])
    }

    @Test("The floating bubble and main window are mutually exclusive")
    func floatingVisibility() {
        #expect(FloatingVisibilityPolicy.shouldShow(
            settingEnabled: true,
            mainWindowPresented: false
        ))
        #expect(!FloatingVisibilityPolicy.shouldShow(
            settingEnabled: true,
            mainWindowPresented: true
        ))
        #expect(!FloatingVisibilityPolicy.shouldShow(
            settingEnabled: false,
            mainWindowPresented: false
        ))
    }

    @Test("The application exposes one maximized main window")
    func mainWindowPolicy() {
        let visibleFrame = CGRect(x: 12, y: 34, width: 1440, height: 900)
        #expect(!MainWindowPresentationPolicy.allowsMultipleMainWindows)
        #expect(MainWindowPresentationPolicy.targetFrame(for: visibleFrame) == visibleFrame)
    }

    @Test("Only OpenAI activity rotates while border thickness stays fixed")
    func animationRules() {
        #expect(IrizIndicatorAnimation.ringWidth(scale: 1) == 4)
        #expect(IrizIndicatorAnimation.ringWidth(scale: 2) == 8)
        #expect(IrizIndicatorAnimation.rotationAngle(
            for: .fixed,
            at: 10,
            reduceMotion: false
        ) == 0)

        let routineMotion = IndicatorPresentation.Motion.api(rotationDuration: 3.2)
        #expect(abs(IrizIndicatorAnimation.rotationAngle(
            for: routineMotion,
            at: 0.8,
            reduceMotion: false
        ) - 90) < 0.001)
        #expect(IrizIndicatorAnimation.rotationAngle(
            for: routineMotion,
            at: 0.8,
            reduceMotion: true
        ) == 0)
    }

    @Test("The guide catalog is complete and stable")
    func scenarioCatalog() {
        let identifiers = IndicatorScenario.all.map(\.id)
        #expect(Set(identifiers).count == identifiers.count)
        #expect(IndicatorScenario.Group.allCases.map(\.title) == [
            "Everyday states",
            "Local activity",
            "OpenAI activity",
            "Outcomes and attention"
        ])
        #expect(IndicatorScenario.all.contains { $0.id == "private-listening" })
        #expect(IndicatorScenario.all.contains { $0.id == "meeting-listening" })
        #expect(IndicatorScenario.all.contains { $0.id == "routine-api" })
        #expect(IndicatorScenario.all.contains { $0.id == "speech-api" })
        #expect(IndicatorScenario.all.contains { $0.id == "intensive-api" })
        #expect(IndicatorScenario.all.contains { $0.id == "blocking-error" })
        #expect(IndicatorScenario.all.contains { $0.id == "api-failure" })
        #expect(IndicatorSimulatorLayout.groupsBeforePreview == [.everyday, .localActivity])
        #expect(IndicatorSimulatorLayout.groupsAfterPreview == [.openAI, .outcomesAndAttention])
    }

    @Test("VoiceOver announces meaningful production presentation changes")
    func announcementPolicy() {
        #expect(IndicatorAnnouncementPolicy.announcement(
            previous: nil,
            next: .observing
        ) == nil)
        #expect(IndicatorAnnouncementPolicy.announcement(
            previous: .observing,
            next: .observing
        ) == nil)

        let announcement = IndicatorAnnouncementPolicy.announcement(
            previous: .observing,
            next: .intensiveAPI
        )
        #expect(announcement?.contains("OpenAI · Intensive") == true)
        #expect(announcement?.contains(OpenAIModelPolicy.consolidation) == true)
    }

    @Test("Simulator hover, focus, pin and Live restoration are isolated UI state")
    func simulatorSelection() {
        var selection = IndicatorSimulatorSelection()
        #expect(selection.previewID == nil)

        selection.setFocused("waiting")
        #expect(selection.previewID == "waiting")
        selection.setHovered("observing", isInside: true)
        #expect(selection.previewID == "observing")
        selection.togglePinned("intensive-api")
        #expect(selection.previewID == "intensive-api")

        selection.setHovered("observing", isInside: false)
        selection.setFocused("private")
        #expect(selection.previewID == "intensive-api")
        selection.togglePinned("intensive-api")
        #expect(selection.previewID == "private")

        selection.returnToLive()
        #expect(selection.previewID == nil)
    }

    private func resolve(
        _ health: CaptureHealth,
        _ snapshot: IndicatorActivitySnapshot
    ) -> IndicatorPresentation {
        IndicatorPresentationResolver.resolve(captureHealth: health, snapshot: snapshot)
    }

    private func local(
        _ context: IndicatorActivityContext,
        at date: Date
    ) -> IndicatorActiveLocalActivity {
        IndicatorActiveLocalActivity(
            id: IndicatorActivityToken(),
            descriptor: IndicatorLocalActivityDescriptor(context: context, startedAt: date)
        )
    }

    private func api(
        _ level: IndicatorAPILevel,
        context: IndicatorActivityContext,
        model: String = OpenAIModelPolicy.frequentAnalysis,
        at date: Date
    ) -> IndicatorActiveAPIActivity {
        IndicatorActiveAPIActivity(
            id: IndicatorActivityToken(),
            descriptor: IndicatorAPIActivityDescriptor(
                task: level == .speech ? .transcription : .observationClassification,
                model: model,
                level: level,
                context: context,
                startedAt: date
            )
        )
    }
}
