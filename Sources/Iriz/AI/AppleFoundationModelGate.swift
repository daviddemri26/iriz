import CryptoKit
import Foundation
import FoundationModels

struct LocalGateModelEnvironment: Equatable, Sendable {
    let availability: LocalModelAvailability
    let fingerprint: AppleModelFingerprint
}

@available(macOS 26.0, *)
protocol LocalGateModelProviding: Sendable {
    func environment(localeIdentifier: String) async -> LocalGateModelEnvironment
    func prewarm() async
    func classify(prompt: String) async throws -> LocalGateVerdict
    func draftEvent(prompt: String) async throws -> LocalEventDraft
}

@available(macOS 26.0, *)
extension LocalGateModelProviding {
    func draftEvent(prompt: String) async throws -> LocalEventDraft {
        throw LocalEventDraftGenerationError.unsupportedProvider
    }
}

enum LocalEventDraftGenerationError: Error, Equatable, Sendable {
    case unsupportedProvider
}

@available(macOS 26.0, *)
protocol LocalGateRouting: Sendable {
    func prewarm(languageTag: String, mode: LocalGateMode) async
    func status(languageTag: String, mode: LocalGateMode) async -> LocalIntelligenceStatus
    func route(_ input: LocalGateInput, mode: LocalGateMode) async -> LocalGateDecision
}

@available(macOS 26.0, *)
actor SystemFoundationModelGateProvider: LocalGateModelProviding {
    static let promptVersion = "local-gate-v1"
    static let schemaVersion = "local-gate-verdict-v1"
    static let localEventPromptVersion = "local-event-v1"
    static let localEventSchemaVersion = "local-event-draft-v1"
    static let contextWindowTokens = 4_096

    private static let instructions = """
    You are a conservative routing gate for a private activity journal.
    Classify only the supplied OCR text or transcript and metadata.
    Return clearlyEmpty only when the content is plainly routine navigation or has no durable human action, decision, commitment, deadline, confirmation, or useful work context.
    Return meaningful when durable work or personal activity is explicit.
    Return uncertain whenever evidence is sparse, ambiguous, or could conceal a meaningful action.
    Never infer a completion, commitment, deadline, transaction, or meeting that is not explicit.
    When in doubt, return uncertain so a cloud model can review the evidence.
    """

    private static let localEventInstructions = """
    You create a low-risk, factual journal observation from only the supplied text and metadata.
    Return only context, research, document, or note.
    Describe what is visibly being read, written, or explored; keep the title under 80 characters and the summary under 240 characters.
    Never create an Action, task, reminder, commitment, promise, deadline, date, meeting, decision, purchase, confirmation, or completion claim.
    Never infer facts that are not explicit in the supplied content.
    """

    private let model: SystemLanguageModel
    private let operatingSystemVersion: OperatingSystemVersion

    init(
        model: SystemLanguageModel = .default,
        operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) {
        self.model = model
        self.operatingSystemVersion = operatingSystemVersion
    }

    func environment(localeIdentifier: String) -> LocalGateModelEnvironment {
        let resolvedLocaleIdentifier = Self.resolvedLocaleIdentifier(localeIdentifier)
        let locale = Locale(identifier: resolvedLocaleIdentifier)
        let availability: LocalModelAvailability

        switch model.availability {
        case .available:
            availability = model.supportsLocale(locale) ? .available : .unsupportedLocale
        case .unavailable(let reason):
            availability = switch reason {
            case .deviceNotEligible: .deviceNotEligible
            case .appleIntelligenceNotEnabled: .appleIntelligenceNotEnabled
            case .modelNotReady: .modelNotReady
            @unknown default: .unknown
            }
        @unknown default:
            availability = .unknown
        }

        return LocalGateModelEnvironment(
            availability: availability,
            fingerprint: AppleModelFingerprint(
                operatingSystemMajor: operatingSystemVersion.majorVersion,
                operatingSystemMinor: operatingSystemVersion.minorVersion,
                contextWindowTokens: Self.contextWindowTokens,
                localeIdentifier: resolvedLocaleIdentifier,
                promptVersion: Self.promptVersion,
                schemaVersion: Self.schemaVersion,
                localEventPromptVersion: Self.localEventPromptVersion,
                localEventSchemaVersion: Self.localEventSchemaVersion
            )
        )
    }

    func prewarm() {
        guard model.isAvailable else { return }
        let session = LanguageModelSession(model: model, instructions: Self.instructions)
        session.prewarm()
    }

    func classify(prompt: String) async throws -> LocalGateVerdict {
        // A session is intentionally never reused across observations: its transcript
        // retains context and could otherwise leak one observation into the next.
        let session = LanguageModelSession(model: model, instructions: Self.instructions)
        session.prewarm()
        let response = try await session.respond(
            to: prompt,
            generating: LocalGateVerdict.self,
            includeSchemaInPrompt: true,
            options: GenerationOptions(
                sampling: .greedy,
                maximumResponseTokens: 16
            )
        )
        return response.content
    }

    func draftEvent(prompt: String) async throws -> LocalEventDraft {
        // Draft generation uses a fresh, text-only session. Reusing the gate session
        // would retain another observation and violate the capability boundary.
        let session = LanguageModelSession(model: model, instructions: Self.localEventInstructions)
        session.prewarm()
        let response = try await session.respond(
            to: prompt,
            generating: LocalEventDraft.self,
            includeSchemaInPrompt: true,
            options: GenerationOptions(
                sampling: .greedy,
                maximumResponseTokens: 192
            )
        )
        return response.content
    }

    private static func resolvedLocaleIdentifier(_ requestedIdentifier: String) -> String {
        let source = requestedIdentifier == "auto" ? Locale.current.identifier : requestedIdentifier
        return Locale.identifier(.bcp47, from: source)
    }
}

@available(macOS 26.0, *)
actor AppleFoundationModelGate: LocalGateRouting {
    private struct CacheEntry: Sendable {
        let verdict: LocalGateVerdict
        let storedAt: Date
    }

    private let provider: any LocalGateModelProviding
    private let registry: AppleQualificationRegistry
    private let cacheTTL: TimeInterval
    private let cacheCapacity: Int
    private let now: @Sendable () -> Date
    private let telemetryHandler: OptimizationTelemetryHandler?
    private let localEventDraftPolicy: LocalEventDraftPolicy
    private var cache: [String: CacheEntry] = [:]

    init(
        provider: any LocalGateModelProviding = SystemFoundationModelGateProvider(),
        registry: AppleQualificationRegistry = .production,
        cacheTTL: TimeInterval = 15 * 60,
        cacheCapacity: Int = 512,
        now: @escaping @Sendable () -> Date = Date.init,
        telemetryHandler: OptimizationTelemetryHandler? = nil,
        localEventDraftPolicy: LocalEventDraftPolicy = .routing
    ) {
        self.provider = provider
        self.registry = registry
        self.cacheTTL = max(0, cacheTTL)
        self.cacheCapacity = max(1, cacheCapacity)
        self.now = now
        self.telemetryHandler = telemetryHandler
        self.localEventDraftPolicy = localEventDraftPolicy
    }

    func prewarm(languageTag: String, mode: LocalGateMode) async {
        guard mode != .disabled else { return }
        let environment = await provider.environment(localeIdentifier: languageTag)
        guard environment.availability == .available else { return }

        if mode == .adaptive {
            guard registry.profile(for: environment.fingerprint)?.gateEnabled == true else { return }
        }
        await provider.prewarm()
    }

    func status(languageTag: String, mode: LocalGateMode) async -> LocalIntelligenceStatus {
        guard mode != .disabled else {
            return .fallback(.disabled)
        }

        let environment = await provider.environment(localeIdentifier: languageTag)
        guard environment.availability == .available else {
            return .fallback(Self.fallbackReason(for: environment.availability))
        }

        guard mode == .adaptive else {
            return .fallback(.shadowMode)
        }
        guard registry.profile(for: environment.fingerprint)?.gateEnabled == true else {
            return .fallback(.unqualifiedModel)
        }
        return .active(environment.fingerprint)
    }

    func route(_ input: LocalGateInput, mode: LocalGateMode) async -> LocalGateDecision {
        let startedAt = ContinuousClock.now
        let decision = await routeWithoutTelemetry(input, mode: mode)
        let metric: OptimizationTelemetryMetric
        if decision.reason == .shadowMode {
            metric = .appleGateShadowCompared
        } else if decision.route == .suppressCloud {
            metric = .appleGateSuppressedCloud
        } else {
            metric = .appleGateUsedCloud
        }
        let latencyMilliseconds = decision.classificationLatencyMilliseconds
            ?? Self.elapsedMilliseconds(since: startedAt)
        let telemetryReason = if decision.reason == .shadowMode, let verdict = decision.verdict {
            Self.telemetryReason(for: verdict)
        } else {
            Self.telemetryReason(for: decision.reason)
        }
        await telemetryHandler?(OptimizationTelemetryRecord(
            metric: metric,
            reason: telemetryReason,
            source: OptimizationTelemetrySource(input.source),
            latencyMilliseconds: latencyMilliseconds,
            fromCache: decision.fromCache,
            isMeeting: input.isMeeting
        ))
        return decision
    }

    private func routeWithoutTelemetry(_ input: LocalGateInput, mode: LocalGateMode) async -> LocalGateDecision {
        let contentFingerprint = Self.contentFingerprint(for: input)

        guard mode != .disabled else {
            return .cloud(reason: .gateDisabled, contentFingerprint: contentFingerprint)
        }

        let environment = await provider.environment(localeIdentifier: input.languageTag)
        if let bypassReason = DeterministicLocalGatePolicy.bypassReason(for: input) {
            return .cloud(
                reason: bypassReason,
                contentFingerprint: contentFingerprint,
                modelFingerprint: environment.fingerprint
            )
        }
        guard environment.availability == .available else {
            return .cloud(
                reason: .unavailable(environment.availability),
                contentFingerprint: contentFingerprint,
                modelFingerprint: environment.fingerprint
            )
        }

        if mode == .adaptive,
           registry.profile(for: environment.fingerprint)?.gateEnabled != true {
            return .cloud(
                reason: .unqualifiedModel,
                contentFingerprint: contentFingerprint,
                modelFingerprint: environment.fingerprint
            )
        }

        let cacheKey = "\(environment.fingerprint.stableIdentifier):\(contentFingerprint)"
        let verdict: LocalGateVerdict
        let fromCache: Bool
        let classificationLatencyMilliseconds: Int?

        if let cachedVerdict = cachedVerdict(for: cacheKey) {
            verdict = cachedVerdict
            fromCache = true
            classificationLatencyMilliseconds = nil
        } else {
            let classificationStartedAt = ContinuousClock.now
            do {
                verdict = try await provider.classify(prompt: Self.prompt(for: input))
                insert(verdict, for: cacheKey)
                fromCache = false
                classificationLatencyMilliseconds = Self.elapsedMilliseconds(since: classificationStartedAt)
            } catch {
                return .cloud(
                    reason: .generationFailed,
                    contentFingerprint: contentFingerprint,
                    modelFingerprint: environment.fingerprint,
                    classificationLatencyMilliseconds: Self.elapsedMilliseconds(since: classificationStartedAt)
                )
            }
        }

        let localEventDraftAttempt: LocalEventDraftAttempt
        if verdict == .meaningful {
            localEventDraftAttempt = await attemptLocalEventDraft(
                for: input,
                environment: environment,
                mode: mode
            )
        } else {
            localEventDraftAttempt = .notAttempted
        }

        if mode == .shadow {
            return .cloud(
                reason: .shadowMode,
                contentFingerprint: contentFingerprint,
                verdict: verdict,
                modelFingerprint: environment.fingerprint,
                fromCache: fromCache,
                classificationLatencyMilliseconds: classificationLatencyMilliseconds,
                localEventDraftAttempt: localEventDraftAttempt
            )
        }

        switch verdict {
        case .clearlyEmpty:
            return LocalGateDecision(
                route: .suppressCloud,
                verdict: verdict,
                reason: .clearlyEmpty,
                contentFingerprint: contentFingerprint,
                modelFingerprint: environment.fingerprint,
                fromCache: fromCache,
                classificationLatencyMilliseconds: classificationLatencyMilliseconds,
                localEventDraftAttempt: localEventDraftAttempt
            )
        case .uncertain:
            return .cloud(
                reason: .uncertain,
                contentFingerprint: contentFingerprint,
                verdict: verdict,
                modelFingerprint: environment.fingerprint,
                fromCache: fromCache,
                classificationLatencyMilliseconds: classificationLatencyMilliseconds,
                localEventDraftAttempt: localEventDraftAttempt
            )
        case .meaningful:
            if localEventDraftAttempt.outcome == .generated,
               localEventDraftAttempt.draft != nil {
                return LocalGateDecision(
                    route: .suppressCloud,
                    verdict: verdict,
                    reason: .meaningful,
                    contentFingerprint: contentFingerprint,
                    modelFingerprint: environment.fingerprint,
                    fromCache: fromCache,
                    classificationLatencyMilliseconds: classificationLatencyMilliseconds,
                    localEventDraftAttempt: localEventDraftAttempt
                )
            }
            return .cloud(
                reason: .meaningful,
                contentFingerprint: contentFingerprint,
                verdict: verdict,
                modelFingerprint: environment.fingerprint,
                fromCache: fromCache,
                classificationLatencyMilliseconds: classificationLatencyMilliseconds,
                localEventDraftAttempt: localEventDraftAttempt
            )
        }
    }

    private func attemptLocalEventDraft(
        for input: LocalGateInput,
        environment: LocalGateModelEnvironment,
        mode: LocalGateMode
    ) async -> LocalEventDraftAttempt {
        // Defense in depth: callers must never be able to turn a bypassed source or
        // risky observation into a local event by invoking this helper directly.
        guard DeterministicLocalGatePolicy.bypassReason(for: input) == nil else {
            return .notAttempted
        }
        switch (mode, localEventDraftPolicy) {
        case (.shadow, .shadowOnly), (.shadow, .routing), (.adaptive, .routing):
            break
        case (.disabled, _), (.adaptive, .disabled), (.adaptive, .shadowOnly), (.shadow, .disabled):
            return .notAttempted
        }
        if mode == .adaptive,
           registry.profile(for: environment.fingerprint)?.localEventDraftEnabled != true {
            return .unqualified
        }

        let startedAt = ContinuousClock.now
        do {
            let draft = try await provider.draftEvent(prompt: Self.localEventPrompt(for: input))
            let validated = try draft.validated()
            return LocalEventDraftAttempt(
                outcome: .generated,
                draft: validated,
                latencyMilliseconds: Self.elapsedMilliseconds(since: startedAt)
            )
        } catch is LocalEventDraftValidationError {
            return LocalEventDraftAttempt(
                outcome: .rejectedOutput,
                draft: nil,
                latencyMilliseconds: Self.elapsedMilliseconds(since: startedAt)
            )
        } catch {
            return LocalEventDraftAttempt(
                outcome: .generationFailed,
                draft: nil,
                latencyMilliseconds: Self.elapsedMilliseconds(since: startedAt)
            )
        }
    }

    func removeAllCachedVerdicts() {
        cache.removeAll(keepingCapacity: true)
    }

    private func cachedVerdict(for key: String) -> LocalGateVerdict? {
        guard let entry = cache[key] else { return nil }
        guard now().timeIntervalSince(entry.storedAt) <= cacheTTL else {
            cache.removeValue(forKey: key)
            return nil
        }
        return entry.verdict
    }

    private func insert(_ verdict: LocalGateVerdict, for key: String) {
        let currentDate = now()
        cache[key] = CacheEntry(verdict: verdict, storedAt: currentDate)

        guard cache.count > cacheCapacity,
              let oldestKey = cache.min(by: { $0.value.storedAt < $1.value.storedAt })?.key else {
            return
        }
        cache.removeValue(forKey: oldestKey)
    }

    private static func prompt(for input: LocalGateInput) -> String {
        let source = input.source.rawValue
        let application = sanitized(input.applicationName, maximumLength: 120)
        let windowTitle = sanitized(input.windowTitle, maximumLength: 240)
        let host = sanitized(input.host, maximumLength: 200)
        let text = sanitized(input.text, maximumLength: 6_000)

        return """
        SOURCE: \(source)
        APPLICATION: \(application)
        WINDOW: \(windowTitle)
        HOST: \(host)
        CONTENT:
        \(text)
        """
    }

    private static func localEventPrompt(for input: LocalGateInput) -> String {
        let source = input.source.rawValue
        let application = sanitized(input.applicationName, maximumLength: 120)
        let windowTitle = sanitized(input.windowTitle, maximumLength: 240)
        let host = sanitized(input.host, maximumLength: 200)
        let text = sanitized(input.text, maximumLength: 6_000)

        return """
        SOURCE: \(source)
        APPLICATION: \(application)
        WINDOW: \(windowTitle)
        HOST: \(host)
        CONTENT:
        \(text)
        """
    }

    private static func elapsedMilliseconds(since startedAt: ContinuousClock.Instant) -> Int {
        let components = startedAt.duration(to: .now).components
        return max(
            0,
            Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
        )
    }

    private static func sanitized(_ value: String?, maximumLength: Int) -> String {
        guard let value else { return "none" }
        let cleaned = value
            .replacingOccurrences(of: "\u{0000}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(maximumLength))
    }

    private static func contentFingerprint(for input: LocalGateInput) -> String {
        let normalizedComponents = [
            input.source.rawValue,
            input.applicationName ?? "",
            input.windowTitle ?? "",
            input.host ?? "",
            input.text,
            input.languageTag,
            input.suppliedContentFingerprint ?? ""
        ].map(DeterministicLocalGatePolicy.normalized)
        let digest = SHA256.hash(data: Data(normalizedComponents.joined(separator: "\u{001f}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func fallbackReason(for availability: LocalModelAvailability) -> LocalIntelligenceFallbackReason {
        switch availability {
        case .available: .unavailable
        case .unsupportedOperatingSystem: .unsupportedOperatingSystem
        case .deviceNotEligible: .deviceNotEligible
        case .appleIntelligenceNotEnabled: .appleIntelligenceNotEnabled
        case .modelNotReady: .modelNotReady
        case .unsupportedLocale: .unsupportedLocale
        case .unknown: .unavailable
        }
    }

    private static func telemetryReason(
        for reason: LocalGateDecisionReason
    ) -> OptimizationTelemetryReason {
        switch reason {
        case .gateDisabled: .gateDisabled
        case .shadowMode: .shadowMode
        case .meeting: .meeting
        case .manualNote: .manualNote
        case .retry: .retry
        case .visualContextRequired: .visualContextRequired
        case .insufficientText: .insufficientText
        case .highRiskSignal: .highRiskSignal
        case .unavailable: .appleModelUnavailable
        case .unqualifiedModel: .unqualifiedAppleModel
        case .clearlyEmpty: .clearlyEmpty
        case .uncertain: .uncertain
        case .meaningful: .meaningful
        case .generationFailed: .generationFailed
        }
    }

    private static func telemetryReason(for verdict: LocalGateVerdict) -> OptimizationTelemetryReason {
        switch verdict {
        case .clearlyEmpty: .clearlyEmpty
        case .uncertain: .uncertain
        case .meaningful: .meaningful
        }
    }
}

enum DeterministicLocalGatePolicy {
    private static let highRiskPhrases = [
        // Commitments and follow-ups.
        "i will", "i'll", "i need to", "i must", "we will", "we need to",
        "agreed to", "i promise", "follow up", "action item", "send by", "due by",
        "je vais", "je dois", "nous allons", "nous devons", "j'ai promis",
        "convenu de", "relancer", "suivi a faire", "a faire avant", "d'ici",

        // Confirmations and irreversible actions.
        "confirmed", "confirmation", "submitted", "successfully sent", "sent successfully",
        "completed", "marked complete", "done", "approved", "accepted", "rejected",
        "signed", "booked", "reserved", "uploaded", "deleted", "published",
        "confirme", "confirmation", "envoye", "soumis", "termine", "finalise",
        "approuve", "accepte", "refuse", "signe", "reserve", "publie", "supprime",

        // Transactions.
        "checkout", "payment", "purchase", "order number", "order #", "invoice",
        "receipt", "transaction", "card ending", "paid", "refund", "subscription renewed",
        "paiement", "achat", "commande", "numero de commande", "facture", "recu",
        "remboursement", "carte se terminant", "abonnement renouvele",

        // Decisions, deadlines, and meetings.
        "decision", "decided", "deadline", "due date", "appointment", "meeting scheduled",
        "rendez-vous", "reunion prevue", "echeance", "date limite", "decide"
    ]

    private static let temporalPatterns = [
        #"\b\d{4}-\d{1,2}-\d{1,2}\b"#,
        #"\b\d{1,2}[/.\-]\d{1,2}(?:[/.\-]\d{2,4})?\b"#,
        #"\b\d{1,2}(?::|h)\d{2}\s*(?:am|pm)?\b"#,
        #"\b(?:today|tomorrow|tonight|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#,
        #"\b(?:aujourd'hui|demain|ce soir|lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche)\b"#,
        #"\b(?:january|february|march|april|may|june|july|august|september|october|november|december)\b"#,
        #"\b(?:janvier|fevrier|mars|avril|mai|juin|juillet|aout|septembre|octobre|novembre|decembre)\b"#,
        #"(?:[$€£¥]|\b(?:usd|eur|gbp|cad|aud)\b)\s*\d|\d[\d.,]*\s*(?:[$€£¥]|\b(?:usd|eur|gbp|cad|aud)\b)"#
    ]

    static func bypassReason(for input: LocalGateInput) -> LocalGateDecisionReason? {
        if input.isMeeting || input.source == .meetingMicrophone || input.source == .meetingSystemAudio {
            return .meeting
        }
        if input.source == .manualNote {
            return .manualNote
        }
        if input.isRetry {
            return .retry
        }
        if input.requiresVisualContext {
            return .visualContextRequired
        }

        let combinedText = [input.windowTitle, input.host, input.text]
            .compactMap { $0 }
            .joined(separator: "\n")
        if containsHighRiskSignal(in: combinedText) {
            return .highRiskSignal
        }
        if isInsufficientText(input.text) {
            return .insufficientText
        }
        return nil
    }

    static func containsHighRiskSignal(in text: String) -> Bool {
        let value = normalized(text)
        if highRiskPhrases.contains(where: value.contains) {
            return true
        }
        return temporalPatterns.contains { pattern in
            value.range(of: pattern, options: .regularExpression) != nil
        }
    }

    static func isInsufficientText(_ text: String) -> Bool {
        let value = normalized(text)
        let alphanumericCount = value.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.alphanumerics.contains(scalar) {
                count += 1
            }
        }
        let wordCount = value.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
        return alphanumericCount < 16 || wordCount < 3
    }

    static func normalized(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }
}
