import Combine
import Foundation

enum ScreenContextVisibility: String, CaseIterable, Equatable, Sendable {
    case available
    case `private`
    case unavailable
}

enum IndicatorActivityContext: String, CaseIterable, Equatable, Hashable, Sendable {
    case screen
    case voice
    case meeting
    case assistant
    case followUp
    case credentials
}

enum IndicatorAPILevel: Int, CaseIterable, Comparable, Equatable, Sendable {
    case routine = 0
    case speech = 1
    case intensive = 2

    static func < (lhs: IndicatorAPILevel, rhs: IndicatorAPILevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var displayName: String {
        switch self {
        case .routine: "Routine"
        case .speech: "Speech"
        case .intensive: "Intensive"
        }
    }

    /// A relative visual cadence, not an estimate of price or elapsed work.
    var rotationDuration: TimeInterval {
        switch self {
        case .routine: 3.2
        case .speech: 1.8
        case .intensive: 0.9
        }
    }
}

enum IndicatorAPITask: String, CaseIterable, Equatable, Sendable {
    case credentialValidation
    case observationClassification
    case originalImageAnalysis
    case transcription
    case diarizedTranscription
    case assistantAnswer
    case eventRefinement
    case followUpMerge
}

struct IndicatorActivityToken: Hashable, Sendable {
    let id: UUID

    init(id: UUID = UUID()) {
        self.id = id
    }
}

struct IndicatorLocalActivityDescriptor: Equatable, Sendable {
    let context: IndicatorActivityContext
    let startedAt: Date

    init(context: IndicatorActivityContext, startedAt: Date = Date()) {
        self.context = context
        self.startedAt = startedAt
    }
}

struct IndicatorAPIActivityDescriptor: Equatable, Sendable {
    let task: IndicatorAPITask
    let model: String
    let level: IndicatorAPILevel
    let context: IndicatorActivityContext
    let startedAt: Date

    init(
        task: IndicatorAPITask,
        model: String,
        level: IndicatorAPILevel,
        context: IndicatorActivityContext,
        startedAt: Date = Date()
    ) {
        self.task = task
        self.model = model
        self.level = level
        self.context = context
        self.startedAt = startedAt
    }
}

struct IndicatorActiveLocalActivity: Identifiable, Equatable, Sendable {
    let id: IndicatorActivityToken
    let descriptor: IndicatorLocalActivityDescriptor
}

struct IndicatorActiveAPIActivity: Identifiable, Equatable, Sendable {
    let id: IndicatorActivityToken
    let descriptor: IndicatorAPIActivityDescriptor
}

enum IndicatorTransientEvent: Equatable, Sendable {
    case success(context: IndicatorActivityContext, occurredAt: Date)
    case apiFailure(context: IndicatorActivityContext, occurredAt: Date)

    var occurredAt: Date {
        switch self {
        case .success(_, let occurredAt), .apiFailure(_, let occurredAt): occurredAt
        }
    }
}

enum IndicatorAPICompletion: Equatable, Sendable {
    case success
    case failure
    case cancelled
}

enum FollowUpIndicatorMutationSource: Equatable, Sendable {
    case iriz
    case manual
    case rawObservation
}

enum FollowUpIndicatorOutcomePolicy {
    static func shouldHighlight(
        previous: Commitment?,
        updated: Commitment?,
        source: FollowUpIndicatorMutationSource
    ) -> Bool {
        guard source == .iriz, let updated else { return false }
        guard let previous else { return updated.origin == .iriz }
        return VisibleFingerprint(previous) != VisibleFingerprint(updated)
    }

    private struct VisibleFingerprint: Equatable {
        let action: String
        let rationale: String
        let summary: String
        let details: String
        let owner: String
        let contextLabel: String?
        let subjectID: String?
        let area: FollowUpArea
        let priorityScore: Int
        let priorityReason: String
        let explicitDueAt: Date?
        let lifecycle: FollowUpLifecycle
        let completionActor: FollowUpCompletionActor?
        let completionEvidence: FollowUpCompletionEvidence?
        let evidenceHint: String?
        let linkedEventIDs: Set<UUID>
        let historyIDs: Set<UUID>

        init(_ value: Commitment) {
            action = value.action
            rationale = value.rationale
            summary = value.summary
            details = value.details
            owner = value.owner
            contextLabel = value.contextLabel
            subjectID = value.subjectID
            area = value.area
            priorityScore = value.priorityScore
            priorityReason = value.priorityReason
            explicitDueAt = value.explicitDueAt
            lifecycle = value.lifecycle
            completionActor = value.completionActor
            completionEvidence = value.completionEvidence
            evidenceHint = value.evidenceHint
            linkedEventIDs = Set(value.linkedEventIDs)
            historyIDs = Set(value.history.map(\.id))
        }
    }
}

struct IndicatorActivitySnapshot: Equatable, Sendable {
    var screenVisibility: ScreenContextVisibility
    var localActivities: [IndicatorActiveLocalActivity]
    var apiActivities: [IndicatorActiveAPIActivity]
    var transientEvent: IndicatorTransientEvent?

    init(
        screenVisibility: ScreenContextVisibility = .unavailable,
        localActivities: [IndicatorActiveLocalActivity] = [],
        apiActivities: [IndicatorActiveAPIActivity] = [],
        transientEvent: IndicatorTransientEvent? = nil
    ) {
        self.screenVisibility = screenVisibility
        self.localActivities = localActivities
        self.apiActivities = apiActivities
        self.transientEvent = transientEvent
    }

    /// The request that drives presentation when calls overlap: highest level,
    /// then most recently started, then token UUID for a fully stable tie-break.
    var dominantAPIActivity: IndicatorActiveAPIActivity? {
        apiActivities.sorted(by: Self.apiPrecedes).first
    }

    var dominantLocalActivity: IndicatorActiveLocalActivity? {
        localActivities.sorted(by: Self.localPrecedes).first
    }

    static func apiPrecedes(_ lhs: IndicatorActiveAPIActivity, _ rhs: IndicatorActiveAPIActivity) -> Bool {
        if lhs.descriptor.level != rhs.descriptor.level {
            return lhs.descriptor.level > rhs.descriptor.level
        }
        if lhs.descriptor.startedAt != rhs.descriptor.startedAt {
            return lhs.descriptor.startedAt > rhs.descriptor.startedAt
        }
        return lhs.id.id.uuidString < rhs.id.id.uuidString
    }

    static func localPrecedes(_ lhs: IndicatorActiveLocalActivity, _ rhs: IndicatorActiveLocalActivity) -> Bool {
        if lhs.descriptor.startedAt != rhs.descriptor.startedAt {
            return lhs.descriptor.startedAt > rhs.descriptor.startedAt
        }
        return lhs.id.id.uuidString < rhs.id.id.uuidString
    }
}

@MainActor
final class IndicatorActivityStore: ObservableObject {
    @Published private(set) var snapshot = IndicatorActivitySnapshot()

    private var screenVisibility: ScreenContextVisibility = .unavailable
    private var localActivities: [IndicatorActivityToken: IndicatorLocalActivityDescriptor] = [:]
    private var apiActivities: [IndicatorActivityToken: IndicatorAPIActivityDescriptor] = [:]
    private var transientEvent: IndicatorTransientEvent?
    private var pendingTransientEvent: IndicatorTransientEvent?
    private var transientClearTask: Task<Void, Never>?

    @discardableResult
    func beginLocal(_ descriptor: IndicatorLocalActivityDescriptor) -> IndicatorActivityToken {
        let token = IndicatorActivityToken()
        localActivities[token] = descriptor
        publish()
        return token
    }

    @discardableResult
    func finishLocal(_ token: IndicatorActivityToken) -> Bool {
        guard localActivities.removeValue(forKey: token) != nil else { return false }
        publish()
        return true
    }

    @discardableResult
    func beginAPI(_ descriptor: IndicatorAPIActivityDescriptor) -> IndicatorActivityToken {
        if let transientEvent {
            transientClearTask?.cancel()
            transientClearTask = nil
            self.transientEvent = nil
            mergePending(transientEvent)
        }
        let token = IndicatorActivityToken()
        apiActivities[token] = descriptor
        publish()
        return token
    }

    @discardableResult
    func finishAPI(
        _ token: IndicatorActivityToken,
        completion: IndicatorAPICompletion
    ) -> Bool {
        guard let descriptor = apiActivities.removeValue(forKey: token) else { return false }
        if completion == .failure {
            let didPresent = recordTransient(
                .apiFailure(context: descriptor.context, occurredAt: Date())
            )
            if !didPresent, apiActivities.isEmpty, presentPendingTransient() { return true }
            if !didPresent { publish() }
            return true
        }
        if apiActivities.isEmpty, presentPendingTransient() { return true }
        publish()
        return true
    }

    func setScreenVisibility(_ visibility: ScreenContextVisibility) {
        guard screenVisibility != visibility else { return }
        screenVisibility = visibility
        publish()
    }

    func emitSuccess(context: IndicatorActivityContext, at date: Date = Date()) {
        _ = recordTransient(.success(context: context, occurredAt: date))
    }

    func emitAPIFailure(context: IndicatorActivityContext, at date: Date = Date()) {
        _ = recordTransient(.apiFailure(context: context, occurredAt: date))
    }

    func clearTransientEvent() {
        transientClearTask?.cancel()
        transientClearTask = nil
        pendingTransientEvent = nil
        guard transientEvent != nil else { return }
        transientEvent = nil
        publish()
    }

    @discardableResult
    private func recordTransient(_ event: IndicatorTransientEvent) -> Bool {
        if shouldCoalesce(event) { return false }
        if !apiActivities.isEmpty {
            mergePending(event)
            return false
        }
        if pendingTransientEvent != nil {
            mergePending(event)
            return presentPendingTransient()
        }
        setTransient(event, duration: 0.9)
        return true
    }

    private func shouldCoalesce(_ event: IndicatorTransientEvent) -> Bool {
        if let pendingTransientEvent {
            switch (pendingTransientEvent, event) {
            case (.apiFailure(_, _), _), (.success(_, _), .success(_, _)):
                return true
            case (.success(_, _), .apiFailure(_, _)):
                break
            }
        }
        guard let transientEvent else { return false }
        let elapsed = event.occurredAt.timeIntervalSince(transientEvent.occurredAt)
        guard elapsed >= 0, elapsed < 0.9 else { return false }
        switch (transientEvent, event) {
        case (.apiFailure(_, _), _), (.success(_, _), .success(_, _)):
            return true
        case (.success(_, _), .apiFailure(_, _)):
            return false
        }
    }

    private func mergePending(_ event: IndicatorTransientEvent) {
        switch (pendingTransientEvent, event) {
        case (.some(.apiFailure(_, _)), _),
             (.some(.success(_, _)), .success(_, _)):
            return
        case (.some(.success(_, _)), .apiFailure(_, _)), (nil, _):
            pendingTransientEvent = event
        }
    }

    @discardableResult
    private func presentPendingTransient() -> Bool {
        guard apiActivities.isEmpty, let pendingTransientEvent else { return false }
        self.pendingTransientEvent = nil
        let presentedAt = Date()
        let event: IndicatorTransientEvent = switch pendingTransientEvent {
        case .success(let context, _): .success(context: context, occurredAt: presentedAt)
        case .apiFailure(let context, _): .apiFailure(context: context, occurredAt: presentedAt)
        }
        setTransient(event, duration: 0.9)
        return true
    }

    private func setTransient(_ event: IndicatorTransientEvent, duration: TimeInterval) {
        transientClearTask?.cancel()
        transientEvent = event
        publish()
        transientClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.transientEvent = nil
            self?.transientClearTask = nil
            self?.publish()
        }
    }

    private func publish() {
        snapshot = IndicatorActivitySnapshot(
            screenVisibility: screenVisibility,
            localActivities: localActivities.map {
                IndicatorActiveLocalActivity(id: $0.key, descriptor: $0.value)
            }.sorted(by: IndicatorActivitySnapshot.localPrecedes),
            apiActivities: apiActivities.map {
                IndicatorActiveAPIActivity(id: $0.key, descriptor: $0.value)
            }.sorted(by: IndicatorActivitySnapshot.apiPrecedes),
            transientEvent: transientEvent
        )
    }
}
