import Foundation

enum OpenAIReasoningEffort: String, Sendable {
    case none
    case low
    case medium
}

struct OpenAIModelConfiguration: Equatable, Sendable {
    let model: String
    let reasoningEffort: OpenAIReasoningEffort
    let maxOutputTokens: Int
}

enum OpenAITask: Sendable {
    case credentialValidation
    case observationClassification
    case eventConsolidation
    case followUpMerge
    case assistantAnswer
    case complexAssistantAnswer
}

enum OpenAIModelPolicy {
    static let frequentAnalysis = "gpt-5.6-luna"
    static let consolidation = "gpt-5.6-terra"
    static let transcription = "gpt-transcribe"
    static let diarizedTranscription = "gpt-4o-transcribe-diarize"

    static func configuration(for task: OpenAITask) -> OpenAIModelConfiguration {
        switch task {
        case .credentialValidation:
            OpenAIModelConfiguration(model: frequentAnalysis, reasoningEffort: .none, maxOutputTokens: 8)
        case .observationClassification:
            OpenAIModelConfiguration(model: frequentAnalysis, reasoningEffort: .none, maxOutputTokens: 2_400)
        case .eventConsolidation, .followUpMerge:
            OpenAIModelConfiguration(model: consolidation, reasoningEffort: .low, maxOutputTokens: 1_400)
        case .assistantAnswer:
            OpenAIModelConfiguration(model: consolidation, reasoningEffort: .low, maxOutputTokens: 1_200)
        case .complexAssistantAnswer:
            OpenAIModelConfiguration(model: consolidation, reasoningEffort: .medium, maxOutputTokens: 1_600)
        }
    }

    static func assistantConfiguration(question: String, candidateCount: Int) -> OpenAIModelConfiguration {
        let isComplex = candidateCount > 12 || question.count > 280
        return configuration(for: isComplex ? .complexAssistantAnswer : .assistantAnswer)
    }
}

enum OpenAIClientError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidResponse
    case requestFailed(status: Int, message: String)
    case malformedStructuredOutput

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Add your OpenAI API key in Settings."
        case .invalidResponse: "OpenAI returned an unreadable response."
        case .requestFailed(let status, let message): "OpenAI request failed (\(status)): \(message)"
        case .malformedStructuredOutput: "OpenAI returned an event that did not match the Iriz format."
        }
    }
}

protocol AIProviding: Sendable {
    func validateAPIKey(_ apiKey: String) async throws
    func interpret(
        observation: Observation,
        imageData: Data?,
        outputLanguage: String,
        followUpDetailLevel: FollowUpDetailLevel,
        knownFollowUpContexts: [String],
        followUpCandidates: [Commitment],
        knownFollowUpSubjects: [FollowUpSubject],
        apiKey: String
    ) async throws -> InterpretedObservation
    func answer(
        question: String,
        candidates: [ActivityEvent],
        conversationContext: [AssistantAnswer],
        outputLanguage: String,
        apiKey: String
    ) async throws -> AssistantAnswer
    func refine(
        event: ActivityEvent,
        outputLanguage: String,
        apiKey: String
    ) async throws -> ActivityEvent
    func mergeFollowUps(
        _ commitments: [Commitment],
        subject: FollowUpSubject?,
        outputLanguage: String,
        apiKey: String
    ) async throws -> FollowUpMergeDraft
    func transcribe(
        wavData: Data,
        diarize: Bool,
        languageTag: String?,
        knownSpeakerReference: Data?,
        apiKey: String
    ) async throws -> String
}

actor OpenAIClient: AIProviding {
    private let session: URLSession
    private let baseURL: URL

    init(session: URLSession = .shared, baseURL: URL = URL(string: "https://api.openai.com/v1")!) {
        self.session = session
        self.baseURL = baseURL
    }

    func validateAPIKey(_ apiKey: String) async throws {
        let data = try OpenAIRequestFactory.validationRequest()
        _ = try await post(path: "responses", body: data, apiKey: apiKey)
    }

    func interpret(
        observation: Observation,
        imageData: Data?,
        outputLanguage: String,
        followUpDetailLevel: FollowUpDetailLevel,
        knownFollowUpContexts: [String],
        followUpCandidates: [Commitment] = [],
        knownFollowUpSubjects: [FollowUpSubject] = [],
        apiKey: String
    ) async throws -> InterpretedObservation {
        let body = try OpenAIRequestFactory.interpretationRequest(
            observation: observation,
            imageData: imageData,
            outputLanguage: outputLanguage,
            followUpDetailLevel: followUpDetailLevel,
            knownFollowUpContexts: knownFollowUpContexts,
            followUpCandidates: followUpCandidates,
            knownFollowUpSubjects: knownFollowUpSubjects
        )
        var data = try await post(path: "responses", body: body, apiKey: apiKey)
        var output = try Self.outputText(from: data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var draft: InterpretationPayload
        do {
            draft = try decoder.decode(InterpretationPayload.self, from: Data(output.utf8))
        } catch {
            throw OpenAIClientError.malformedStructuredOutput
        }
        if draft.needsOriginalImage, imageData != nil {
            let detailedBody = try OpenAIRequestFactory.interpretationRequest(
                observation: observation,
                imageData: imageData,
                outputLanguage: outputLanguage,
                followUpDetailLevel: followUpDetailLevel,
                knownFollowUpContexts: knownFollowUpContexts,
                followUpCandidates: followUpCandidates,
                knownFollowUpSubjects: knownFollowUpSubjects,
                imageDetail: "original"
            )
            data = try await post(path: "responses", body: detailedBody, apiKey: apiKey)
            output = try Self.outputText(from: data)
            do {
                draft = try decoder.decode(InterpretationPayload.self, from: Data(output.utf8))
            } catch {
                throw OpenAIClientError.malformedStructuredOutput
            }
        }

        let evidence = EvidenceReference(
            observationID: observation.id,
            source: observation.source,
            capturedAt: observation.capturedAt,
            expiresAt: observation.expiresAt,
            mediaIdentifier: observation.mediaIdentifier,
            excerpt: String(observation.text.prefix(500))
        )
        let event = draft.event.map {
            ActivityEvent(
                startedAt: observation.capturedAt,
                endedAt: observation.capturedAt,
                kind: EventKind(rawValue: $0.kind) ?? .other,
                status: EventStatus(rawValue: $0.status) ?? .uncertain,
                importance: EventImportance(rawValue: $0.importance) ?? .normal,
                title: $0.title,
                summary: $0.summary,
                details: $0.details,
                languageTag: draft.languageTag,
                entities: $0.entities,
                urls: $0.urls.compactMap(URL.init(string:)),
                sourceApplications: [observation.applicationName].compactMap { $0 },
                confidence: $0.confidence,
                evidence: [evidence]
            )
        }
        let commitments = draft.commitments.map { item in
            let dueSource = item.dueSource.flatMap(FollowUpDueSource.init(rawValue:))
            let explicitDueAt = dueSource == .explicitEvidence
                ? Self.parseISODate(item.explicitDueAt)
                : nil
            return CommitmentDraft(
                operation: FollowUpDraftOperation(rawValue: item.operation) ?? .create,
                existingCommitmentID: item.existingCommitmentID.flatMap(UUID.init(uuidString:)),
                owner: item.owner,
                action: item.action,
                rationale: item.rationale,
                summary: item.summary,
                details: item.details,
                explicitDueAt: explicitDueAt,
                suggestedReviewAt: nil,
                contextLabel: item.contextLabel,
                area: FollowUpArea(rawValue: item.area) ?? .uncategorized,
                priorityScore: item.priorityScore,
                priorityReason: item.priorityReason,
                dueSource: explicitDueAt == nil ? nil : .explicitEvidence,
                evidenceStrength: FollowUpEvidenceStrength(rawValue: item.evidenceStrength) ?? .weak,
                confidence: item.confidence,
                state: item.operation == FollowUpDraftOperation.complete.rawValue ? .completed : .needsAttention
            )
        }
        let normalizedEvent = event ?? Self.fallbackFollowUpEvent(
            observation: observation,
            commitments: commitments,
            languageTag: draft.languageTag,
            evidence: evidence
        )
        return InterpretedObservation(
            shouldCreateEvent: draft.shouldCreateEvent || normalizedEvent != nil,
            event: normalizedEvent,
            commitments: commitments,
            needsOriginalImage: draft.needsOriginalImage,
            explanation: draft.explanation
        )
    }

    func answer(
        question: String,
        candidates: [ActivityEvent],
        conversationContext: [AssistantAnswer],
        outputLanguage: String,
        apiKey: String
    ) async throws -> AssistantAnswer {
        let body = try OpenAIRequestFactory.answerRequest(
            question: question,
            candidates: candidates,
            conversationContext: conversationContext,
            outputLanguage: outputLanguage
        )
        let data = try await post(path: "responses", body: body, apiKey: apiKey)
        let output = try Self.outputText(from: data)
        let payload: AnswerPayload
        do {
            payload = try JSONDecoder().decode(AnswerPayload.self, from: Data(output.utf8))
        } catch {
            throw OpenAIClientError.malformedStructuredOutput
        }
        let selected = Set(payload.eventIDs.compactMap(UUID.init(uuidString:)))
        let citedEvents = candidates.filter { selected.contains($0.id) }
        let citations = citedEvents.map {
            AssistantCitation(eventID: $0.id, title: $0.title, timestamp: $0.startedAt, url: $0.urls.first)
        }
        return AssistantAnswer(question: question, text: payload.answer, citations: citations)
    }

    func refine(
        event: ActivityEvent,
        outputLanguage: String,
        apiKey: String
    ) async throws -> ActivityEvent {
        let body = try OpenAIRequestFactory.refinementRequest(event: event, outputLanguage: outputLanguage)
        let data = try await post(path: "responses", body: body, apiKey: apiKey)
        let output = try Self.outputText(from: data)
        let payload: EventPayload
        do {
            payload = try JSONDecoder().decode(EventPayload.self, from: Data(output.utf8))
        } catch {
            throw OpenAIClientError.malformedStructuredOutput
        }
        var refined = event
        refined.title = payload.title
        refined.summary = payload.summary
        refined.details = payload.details
        refined.entities = Array(Set(event.entities + payload.entities)).sorted()
        refined.importance = max(event.importance, EventImportance(rawValue: payload.importance) ?? event.importance)
        if event.status != .completed {
            refined.status = EventStatus(rawValue: payload.status) ?? event.status
        }
        refined.confidence = min(max(payload.confidence, 0), 1)
        refined.updatedAt = Date()
        return refined
    }

    func mergeFollowUps(
        _ commitments: [Commitment],
        subject: FollowUpSubject?,
        outputLanguage: String,
        apiKey: String
    ) async throws -> FollowUpMergeDraft {
        guard commitments.count >= 2 else { throw OpenAIClientError.malformedStructuredOutput }
        let body = try OpenAIRequestFactory.followUpMergeRequest(
            commitments: commitments,
            subject: subject,
            outputLanguage: outputLanguage
        )
        let data = try await post(path: "responses", body: body, apiKey: apiKey)
        let output = try Self.outputText(from: data)
        let payload: FollowUpMergePayload
        do {
            payload = try JSONDecoder().decode(FollowUpMergePayload.self, from: Data(output.utf8))
        } catch {
            throw OpenAIClientError.malformedStructuredOutput
        }
        let dueSource = payload.dueSource.flatMap(FollowUpDueSource.init(rawValue:))
        let explicitDueAt = dueSource == .explicitEvidence ? Self.parseISODate(payload.dueAt) : nil
        return FollowUpMergeDraft(
            action: payload.action,
            summary: payload.summary,
            details: payload.details,
            contextLabel: payload.contextLabel,
            area: FollowUpArea(rawValue: payload.area) ?? .uncategorized,
            priorityScore: payload.priorityScore,
            priorityReason: payload.priorityReason,
            dueAt: explicitDueAt,
            dueSource: explicitDueAt == nil ? nil : .explicitEvidence,
            confidence: payload.confidence,
            relationship: FollowUpMergeRelationship(rawValue: payload.relationship) ?? .uncertain,
            relationshipReason: payload.relationshipReason
        )
    }

    func transcribe(
        wavData: Data,
        diarize: Bool,
        languageTag: String?,
        knownSpeakerReference: Data?,
        apiKey: String
    ) async throws -> String {
        let boundary = "Iriz-\(UUID().uuidString)"
        let model = diarize ? OpenAIModelPolicy.diarizedTranscription : OpenAIModelPolicy.transcription
        let body = OpenAIRequestFactory.transcriptionRequest(
            wavData: wavData,
            boundary: boundary,
            model: model,
            languageTag: languageTag,
            knownSpeakerReference: knownSpeakerReference
        )
        var request = URLRequest(url: baseURL.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let data = try await perform(request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAIClientError.invalidResponse
        }
        if diarize, let segments = object["segments"] as? [[String: Any]] {
            let labeled = segments.compactMap { segment -> String? in
                guard let text = segment["text"] as? String else { return nil }
                let speaker = segment["speaker"] as? String ?? "Speaker"
                return "\(speaker): \(text)"
            }
            if !labeled.isEmpty { return labeled.joined(separator: "\n") }
        }
        guard let text = object["text"] as? String else { throw OpenAIClientError.invalidResponse }
        return text
    }

    private func post(path: String, body: Data, apiKey: String) async throws -> Data {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OpenAIClientError.missingAPIKey }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenAIClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = Self.errorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw OpenAIClientError.requestFailed(status: http.statusCode, message: message)
        }
        return data
    }

    private static func outputText(from data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = root["output"] as? [[String: Any]] else {
            throw OpenAIClientError.invalidResponse
        }
        for item in output {
            guard let content = item["content"] as? [[String: Any]] else { continue }
            if let text = content.first(where: { ($0["type"] as? String) == "output_text" })?["text"] as? String {
                return text
            }
        }
        throw OpenAIClientError.invalidResponse
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }

    private static func parseISODate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func fallbackFollowUpEvent(
        observation: Observation,
        commitments: [CommitmentDraft],
        languageTag: String,
        evidence: EvidenceReference
    ) -> ActivityEvent? {
        guard let first = commitments.first else { return nil }
        let confidence = commitments.map(\.confidence).max() ?? first.confidence
        let priority = commitments.map(\.priorityScore).max() ?? first.priorityScore
        let summary = first.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? first.rationale
            : first.summary
        let title = first.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (observation.windowTitle ?? "Follow-up evidence")
            : first.action
        return ActivityEvent(
            startedAt: observation.capturedAt,
            endedAt: observation.capturedAt,
            kind: .task,
            status: commitments.contains(where: { $0.operation == .complete }) ? .completed : .inProgress,
            importance: priority >= 8 ? .important : .normal,
            title: title,
            summary: summary.isEmpty ? String(observation.text.prefix(500)) : summary,
            details: String(observation.text.prefix(1_500)),
            languageTag: languageTag,
            urls: [observation.url].compactMap { $0 },
            sourceApplications: [observation.applicationName].compactMap { $0 },
            confidence: confidence,
            evidence: [evidence]
        )
    }
}

enum OpenAIRequestFactory {
    static func validationRequest() throws -> Data {
        let policy = OpenAIModelPolicy.configuration(for: .credentialValidation)
        return try jsonData([
            "model": policy.model,
            "input": "Reply with OK.",
            "max_output_tokens": policy.maxOutputTokens,
            "reasoning": ["effort": policy.reasoningEffort.rawValue],
            "store": false
        ])
    }

    static func interpretationRequest(
        observation: Observation,
        imageData: Data?,
        outputLanguage: String,
        followUpDetailLevel: FollowUpDetailLevel = .standard,
        knownFollowUpContexts: [String] = [],
        followUpCandidates: [Commitment] = [],
        knownFollowUpSubjects: [FollowUpSubject] = [],
        imageDetail: String = "low"
    ) throws -> Data {
        let policy = OpenAIModelPolicy.configuration(for: .observationClassification)
        var content: [[String: Any]] = [[
            "type": "input_text",
            "text": interpretationPrompt(
                observation: observation,
                outputLanguage: outputLanguage,
                followUpDetailLevel: followUpDetailLevel,
                knownFollowUpContexts: knownFollowUpContexts,
                followUpCandidates: followUpCandidates,
                knownFollowUpSubjects: knownFollowUpSubjects
            )
        ]]
        if let imageData {
            content.append([
                "type": "input_image",
                "image_url": "data:image/jpeg;base64,\(imageData.base64EncodedString())",
                "detail": imageDetail
            ])
        }
        return try jsonData([
            "model": policy.model,
            "input": [["role": "user", "content": content]],
            "reasoning": ["effort": policy.reasoningEffort.rawValue],
            "max_output_tokens": policy.maxOutputTokens,
            "store": false,
            "text": ["format": interpretationFormat]
        ])
    }

    static func answerRequest(
        question: String,
        candidates: [ActivityEvent],
        conversationContext: [AssistantAnswer] = [],
        outputLanguage: String
    ) throws -> Data {
        let policy = OpenAIModelPolicy.assistantConfiguration(
            question: question,
            candidateCount: candidates.count
        )
        let context = candidates.map { event -> [String: Any] in
            [
                "id": event.id.uuidString,
                "time": ISO8601DateFormatter().string(from: event.startedAt),
                "title": event.title,
                "summary": event.summary,
                "details": event.details,
                "entities": event.entities,
                "urls": event.urls.map(\.absoluteString),
                "status": event.status.rawValue
            ]
        }
        let previousTurns = conversationContext.suffix(4).map { answer -> [String: String] in
            [
                "question": String(answer.question.prefix(500)),
                "answer": String(answer.text.prefix(1_500))
            ]
        }
        let prompt = """
        Answer the user's question using only the candidate Iriz events below. Write in \(outputLanguage).
        Be conversational and precise. Use concise Markdown when it improves readability: short paragraphs, **bold** key facts, and compact lists.
        Previous turns are conversational context for follow-up wording only; they are not evidence. Every factual claim must still be supported by a candidate event.
        If the evidence does not establish an action, say \"No matching evidence was found\".
        Include only IDs for events that directly support the answer. Never invent a URL, company, date, or action.

        Previous turns in this conversation: \(try jsonString(previousTurns))
        Question: \(question)
        Candidate events: \(try jsonString(context))
        """
        return try jsonData([
            "model": policy.model,
            "input": prompt,
            "reasoning": ["effort": policy.reasoningEffort.rawValue],
            "max_output_tokens": policy.maxOutputTokens,
            "store": false,
            "text": ["format": answerFormat]
        ])
    }

    static func refinementRequest(event: ActivityEvent, outputLanguage: String) throws -> Data {
        let policy = OpenAIModelPolicy.configuration(for: .eventConsolidation)
        let source: [String: Any] = [
            "kind": event.kind.rawValue,
            "status": event.status.rawValue,
            "importance": event.importance.rawValue,
            "title": event.title,
            "summary": event.summary,
            "details": event.details,
            "entities": event.entities,
            "urls": event.urls.map(\.absoluteString),
            "confidence": event.confidence
        ]
        let prompt = """
        Refine one meaningful Iriz event in \(outputLanguage). Make the title short and human, the summary factual, and the details useful for future retrieval.
        Preserve evidence boundaries. Never invent a person, company, URL, date, completion, purchase, submission, or commitment. A completed status requires explicit confirmation already present in the input.
        Return every URL exactly as provided. Prefer a cautious status when the evidence is ambiguous.

        Event: \(try jsonString(source))
        """
        return try jsonData([
            "model": policy.model,
            "input": prompt,
            "reasoning": ["effort": policy.reasoningEffort.rawValue],
            "max_output_tokens": policy.maxOutputTokens,
            "store": false,
            "text": ["format": refinementFormat]
        ])
    }

    static func followUpMergeRequest(
        commitments: [Commitment],
        subject: FollowUpSubject?,
        outputLanguage: String
    ) throws -> Data {
        let policy = OpenAIModelPolicy.configuration(for: .followUpMerge)
        let values = commitments.prefix(50).map { commitment -> [String: Any] in
            [
                "id": commitment.id.uuidString,
                "action": commitment.action,
                "summary": commitment.summary,
                "details": commitment.details,
                "owner": commitment.owner,
                "subject": commitment.contextLabel ?? "Uncategorized",
                "area": commitment.area.rawValue,
                "priority": commitment.aiPriorityScore,
                "dueAt": commitment.dueAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
                "dueSource": commitment.dueSource?.rawValue ?? NSNull()
            ]
        }
        let prompt = """
        Assess whether these Iriz follow-ups belong in one clear actionable follow-up, then prepare the best possible merge in \(outputLanguage).
        Use relationship=unrelated only when the actions clearly concern different obligations, projects, people, or outcomes and combining them would be misleading. Use uncertain when the connection is plausible but weak. Otherwise use related.
        Give a short factual relationshipReason. Do not mark items unrelated merely because they have different wording or subjects when they contribute to the same outcome.
        Preserve every distinct obligation in the summary or details, but write one concise action title.
        Do not invent a person, deadline, completion, URL, or fact. Prefer the supplied subject \(subject?.name ?? "only when supported").
        Return a priority from 0 to 10. Treat priority as consequence and urgency, not confidence.
        The caller will preserve authoritative user-entered priority, subject, and deadlines; provide the best evidence-based result for all other fields.

        Follow-ups: \(try jsonString(values))
        """
        return try jsonData([
            "model": policy.model,
            "input": prompt,
            "reasoning": ["effort": policy.reasoningEffort.rawValue],
            "max_output_tokens": policy.maxOutputTokens,
            "store": false,
            "text": ["format": followUpMergeFormat]
        ])
    }

    static func transcriptionRequest(
        wavData: Data,
        boundary: String,
        model: String,
        languageTag: String?,
        knownSpeakerReference: Data?
    ) -> Data {
        var body = Data()
        body.appendMultipart(name: "model", value: model, boundary: boundary)
        let responseFormat = model == OpenAIModelPolicy.diarizedTranscription ? "diarized_json" : "json"
        body.appendMultipart(name: "response_format", value: responseFormat, boundary: boundary)
        if model == OpenAIModelPolicy.diarizedTranscription {
            body.appendMultipart(name: "chunking_strategy", value: "auto", boundary: boundary)
            if let knownSpeakerReference {
                body.appendMultipart(name: "known_speaker_names[]", value: "You", boundary: boundary)
                body.appendMultipart(
                    name: "known_speaker_references[]",
                    value: "data:audio/wav;base64,\(knownSpeakerReference.base64EncodedString())",
                    boundary: boundary
                )
            }
        }
        if let languageTag, languageTag != "auto" {
            let language = String(languageTag.prefix(2))
            let field = model == OpenAIModelPolicy.transcription ? "languages[]" : "language"
            body.appendMultipart(name: field, value: language, boundary: boundary)
        }
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"iriz.wav\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        body.append(wavData)
        body.append("\r\n--\(boundary)--\r\n")
        return body
    }

    private static func interpretationPrompt(
        observation: Observation,
        outputLanguage: String,
        followUpDetailLevel: FollowUpDetailLevel,
        knownFollowUpContexts: [String],
        followUpCandidates: [Commitment],
        knownFollowUpSubjects: [FollowUpSubject]
    ) -> String {
        let concreteSubjects = knownFollowUpSubjects.filter {
            !FollowUpContextGrouper.isGenericSubjectName($0.name)
        }
        let contexts = concreteSubjects.isEmpty
            ? knownFollowUpContexts.filter { !FollowUpContextGrouper.isGenericSubjectName($0) }
            : concreteSubjects.map(\.name)
        let contextGuidance = contexts.isEmpty
            ? "No existing custom follow-up contexts are available yet."
            : "Existing follow-up contexts: \(contexts.joined(separator: ", ")). Reuse an exact existing label whenever it fits."
        let candidates = followUpCandidates.prefix(8).map { commitment -> [String: Any] in
            [
                "id": commitment.id.uuidString,
                "action": commitment.action,
                "summary": commitment.summary,
                "subjectID": commitment.subjectID ?? "",
                "subject": commitment.contextLabel ?? "Uncategorized",
                "area": commitment.area.rawValue,
                "priority": commitment.aiPriorityScore,
                "createdDetailLevel": commitment.detailLevelAtCreation.rawValue,
                "dueAt": commitment.dueAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull()
            ]
        }
        let subjectCatalog = concreteSubjects.prefix(12).map { subject -> [String: Any] in
            [
                "id": subject.id,
                "name": subject.name,
                "area": subject.area.rawValue,
                "aliases": Array(subject.aliases).sorted()
            ]
        }
        return """
        You are Iriz, a private activity-memory classifier. Analyze this single observation as evidence, not as certainty.
        Prefer human actions (application submitted, purchase confirmed, appointment booked, decision made, promise, useful meeting) over technical activity.
        A page view or form being edited is observed/inProgress, never completed. Use completed only when confirmation evidence is explicit.
        Create no event for routine navigation or low-value app/window changes. If useful only as secondary context, use kind=context and importance=0.
        Extract exact companies, roles, products, people and URLs only when present. Do not infer missing URLs.
        Write title, summary and details in \(outputLanguage). Use a concise title and factual summary.
        Extract a follow-up only when confidence is at least 0.60, or when the evidence contains an explicit obligation or deadline. Do not create a "maybe" status.
        Give every follow-up an integer priorityScore from 0 to 10 based on consequence, urgency, explicit deadline, and usefulness. Priority is not confidence.
        A deadline is allowed only when an exact date or time is explicitly present in the observation and directly applies to the action. Put that date in explicitDueAt, set dueSource=explicitEvidence, and cite the evidence in rationale. Otherwise both explicitDueAt and suggestedReviewAt must be null. Never invent a review date or use a date merely visible in the interface.
        Detail level for newly created follow-ups: \(followUpDetailLevel.displayName). \(detailLevelGuidance(followUpDetailLevel)) This setting applies only to operation=create. For update or complete, preserve each candidate's action and summary verbatim, retain its createdDetailLevel, and use details only for additive context. Never split, combine, broaden, narrow, or otherwise reformulate an existing candidate because of the current setting.
        Treat area and contextLabel as different fields: area is only the broad Work, Personal, or Uncategorized type. contextLabel must be a concrete, reusable subject such as Client Acme, Lafayette Website, Kids Activities, or Vacation with Maya. Never use Work, Personal, General, Other, or Uncategorized as contextLabel when the evidence supports anything more precise. Prefer the client, project, website, family activity, person, or durable topic actually named by the evidence, while avoiding a unique subject for every individual action. \(contextGuidance)
        Compare only against the bounded candidate follow-ups below. Use operation=update or operation=complete only with an exact candidate id; otherwise use create and a null id.
        Whenever commitments is non-empty, set shouldCreateEvent=true and include a compact supporting event for the same observation.
        Complete only when the observation contains explicit or strong completion proof tied to the same action. Weak evidence must use update with evidenceStrength=weak.
        Preserve candidate fields unless the new evidence genuinely improves them. Never dismiss or snooze automatically.

        Subject catalog: \((try? jsonString(subjectCatalog)) ?? "[]")
        Candidate follow-ups: \((try? jsonString(candidates)) ?? "[]")

        Captured: \(ISO8601DateFormatter().string(from: observation.capturedAt))
        Application: \(observation.applicationName ?? "Unknown")
        Window: \(observation.windowTitle ?? "Unknown")
        URL: \(observation.url?.absoluteString ?? "Unknown")
        Meeting: \(observation.isMeeting)
        OCR or transcript:\n\(String(observation.text.prefix(12_000)))
        """
    }

    private static func detailLevelGuidance(_ level: FollowUpDetailLevel) -> String {
        switch level {
        case .outcome:
            "For operation=create, create very few durable outcome-level follow-ups. Bundle related milestones and steps into one broad action, such as Continue developing Iriz on the new version."
        case .milestone:
            "For operation=create, create one follow-up per major deliverable or phase. Bundle the concrete steps required to reach the same milestone."
        case .standard:
            "For operation=create, create one follow-up per distinct, meaningful action or deliverable. Keep naturally related steps together."
        case .detailed:
            "For operation=create, create separate follow-ups for clear concrete steps when they can be acted on independently, while avoiding duplicate or trivial tiles."
        case .micro:
            "For operation=create, create granular follow-ups for the smallest concrete next actions. Multiple tiles are appropriate when each micro-task can be completed independently."
        }
    }

    private static var interpretationFormat: [String: Any] {[
        "type": "json_schema",
        "name": "iriz_observation",
        "strict": true,
        "schema": [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "shouldCreateEvent": ["type": "boolean"],
                "needsOriginalImage": ["type": "boolean"],
                "languageTag": ["type": "string"],
                "explanation": ["type": "string"],
                "event": [
                    "anyOf": [eventSchema, ["type": "null"]]
                ],
                "commitments": ["type": "array", "items": commitmentSchema]
            ],
            "required": ["shouldCreateEvent", "needsOriginalImage", "languageTag", "explanation", "event", "commitments"]
        ]
    ]}

    private static var eventSchema: [String: Any] {[
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "kind": ["type": "string", "enum": EventKind.allCases.map(\.rawValue)],
            "status": ["type": "string", "enum": EventStatus.allCases.map(\.rawValue)],
            "importance": ["type": "integer", "minimum": 0, "maximum": 3],
            "title": ["type": "string"],
            "summary": ["type": "string"],
            "details": ["type": "string"],
            "entities": ["type": "array", "items": ["type": "string"]],
            "urls": ["type": "array", "items": ["type": "string"]],
            "confidence": ["type": "number", "minimum": 0, "maximum": 1]
        ],
        "required": ["kind", "status", "importance", "title", "summary", "details", "entities", "urls", "confidence"]
    ]}

    private static var commitmentSchema: [String: Any] {[
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "operation": ["type": "string", "enum": ["create", "update", "complete"]],
            "existingCommitmentID": ["type": ["string", "null"]],
            "owner": ["type": "string"],
            "action": ["type": "string"],
            "rationale": ["type": "string"],
            "summary": ["type": "string"],
            "details": ["type": "string"],
            "explicitDueAt": ["type": ["string", "null"]],
            "suggestedReviewAt": ["type": ["string", "null"]],
            "contextLabel": ["type": "string"],
            "area": ["type": "string", "enum": FollowUpArea.allCases.map(\.rawValue)],
            "priorityScore": ["type": "integer", "minimum": 0, "maximum": 10],
            "priorityReason": ["type": "string"],
            "dueSource": ["type": ["string", "null"], "enum": [FollowUpDueSource.explicitEvidence.rawValue, NSNull()]],
            "evidenceStrength": ["type": "string", "enum": ["weak", "strong", "explicit"]],
            "confidence": ["type": "number", "minimum": 0, "maximum": 1],
        ],
        "required": ["operation", "existingCommitmentID", "owner", "action", "rationale", "summary", "details", "explicitDueAt", "suggestedReviewAt", "contextLabel", "area", "priorityScore", "priorityReason", "dueSource", "evidenceStrength", "confidence"]
    ]}

    private static var answerFormat: [String: Any] {[
        "type": "json_schema",
        "name": "iriz_answer",
        "strict": true,
        "schema": [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "answer": ["type": "string"],
                "eventIDs": ["type": "array", "items": ["type": "string"]]
            ],
            "required": ["answer", "eventIDs"]
        ]
    ]}

    private static var refinementFormat: [String: Any] {[
        "type": "json_schema",
        "name": "iriz_event_refinement",
        "strict": true,
        "schema": eventSchema
    ]}

    private static var followUpMergeFormat: [String: Any] {[
        "type": "json_schema",
        "name": "iriz_follow_up_merge",
        "strict": true,
        "schema": [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "action": ["type": "string"],
                "summary": ["type": "string"],
                "details": ["type": "string"],
                "contextLabel": ["type": "string"],
                "area": ["type": "string", "enum": FollowUpArea.allCases.map(\.rawValue)],
                "priorityScore": ["type": "integer", "minimum": 0, "maximum": 10],
                "priorityReason": ["type": "string"],
                "dueAt": ["type": ["string", "null"]],
                "dueSource": ["type": ["string", "null"], "enum": [FollowUpDueSource.explicitEvidence.rawValue, NSNull()]],
                "confidence": ["type": "number", "minimum": 0, "maximum": 1],
                "relationship": ["type": "string", "enum": ["related", "uncertain", "unrelated"]],
                "relationshipReason": ["type": "string"]
            ],
            "required": ["action", "summary", "details", "contextLabel", "area", "priorityScore", "priorityReason", "dueAt", "dueSource", "confidence", "relationship", "relationshipReason"]
        ]
    ]}

    private static func jsonData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func jsonString(_ object: Any) throws -> String {
        String(decoding: try jsonData(object), as: UTF8.self)
    }
}

private struct InterpretationPayload: Codable {
    var shouldCreateEvent: Bool
    var needsOriginalImage: Bool
    var languageTag: String
    var explanation: String
    var event: EventPayload?
    var commitments: [CommitmentPayload]
}

private struct EventPayload: Codable {
    var kind: String
    var status: String
    var importance: Int
    var title: String
    var summary: String
    var details: String
    var entities: [String]
    var urls: [String]
    var confidence: Double
}

private struct CommitmentPayload: Codable {
    var operation: String
    var existingCommitmentID: String?
    var owner: String
    var action: String
    var rationale: String
    var summary: String
    var details: String
    var explicitDueAt: String?
    var suggestedReviewAt: String?
    var contextLabel: String
    var area: String
    var priorityScore: Int
    var priorityReason: String
    var dueSource: String?
    var evidenceStrength: String
    var confidence: Double
}

private struct FollowUpMergePayload: Codable {
    var action: String
    var summary: String
    var details: String
    var contextLabel: String
    var area: String
    var priorityScore: Int
    var priorityReason: String
    var dueAt: String?
    var dueSource: String?
    var confidence: Double
    var relationship: String
    var relationshipReason: String
}

private struct AnswerPayload: Codable {
    var answer: String
    var eventIDs: [String]
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }

    mutating func appendMultipart(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append("\(value)\r\n")
    }
}
