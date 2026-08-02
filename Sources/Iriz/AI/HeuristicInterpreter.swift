import Foundation

enum HeuristicInterpreter {
    static func interpret(_ observation: Observation, languageTag: String = "en-US") -> InterpretedObservation {
        let value = [observation.windowTitle, observation.text, observation.url?.absoluteString]
            .compactMap { $0 }
            .joined(separator: "\n")
        let normalized = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()

        let result: (EventKind, EventStatus, EventImportance, String)?
        if containsAny(normalized, ["application submitted", "candidature envoyee", "thank you for applying", "we received your application"]) {
            result = (.application, .completed, .important, "Job application submitted")
        } else if containsAny(normalized, ["order confirmed", "purchase confirmed", "merci pour votre commande", "order number", "confirmation de commande"]) {
            result = (.purchase, .completed, .important, "Purchase confirmed")
        } else if containsAny(normalized, ["appointment confirmed", "rendez-vous confirme", "booking confirmed", "reservation confirmed"]) {
            result = (.appointment, .completed, .important, "Appointment booked")
        } else if containsAny(normalized, ["checkout", "payment", "paiement", "review your order"]) {
            result = (.purchase, .inProgress, .normal, "Purchase in progress")
        } else if containsAny(normalized, ["apply now", "submit application", "postuler", "job description"]) {
            result = (.application, .observed, .normal, "Job opportunity reviewed")
        } else {
            result = nil
        }

        guard let result else {
            return InterpretedObservation(
                shouldCreateEvent: false,
                event: nil,
                commitments: [],
                needsOriginalImage: false,
                explanation: "No durable human action was detected locally."
            )
        }

        let evidence = EvidenceReference(
            observationID: observation.id,
            source: observation.source,
            capturedAt: observation.capturedAt,
            expiresAt: observation.expiresAt,
            mediaIdentifier: observation.mediaIdentifier,
            excerpt: String(observation.text.prefix(500))
        )
        let event = ActivityEvent(
            startedAt: observation.capturedAt,
            endedAt: observation.capturedAt,
            kind: result.0,
            status: result.1,
            importance: result.2,
            title: result.3,
            summary: summary(for: result.0, status: result.1, observation: observation),
            details: String(observation.text.prefix(1_500)),
            languageTag: languageTag,
            entities: [],
            urls: [observation.url].compactMap { $0 },
            sourceApplications: [observation.applicationName].compactMap { $0 },
            confidence: result.1 == .completed ? 0.82 : 0.68,
            evidence: [evidence]
        )
        return InterpretedObservation(
            shouldCreateEvent: true,
            event: event,
            commitments: [],
            needsOriginalImage: false,
            explanation: "A recognizable action state was detected locally."
        )
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains(where: text.contains)
    }

    private static func summary(for kind: EventKind, status: EventStatus, observation: Observation) -> String {
        let place = observation.url?.host() ?? observation.applicationName ?? "the active app"
        return switch (kind, status) {
        case (.application, .completed): "An application confirmation was visible on \(place)."
        case (.application, _): "A job opportunity or application flow was viewed on \(place); no submission confirmation was found."
        case (.purchase, .completed): "A purchase confirmation was visible on \(place)."
        case (.purchase, _): "A checkout flow was visible on \(place); no purchase confirmation was found."
        case (.appointment, .completed): "An appointment confirmation was visible on \(place)."
        default: "A potentially useful action was detected on \(place)."
        }
    }
}
