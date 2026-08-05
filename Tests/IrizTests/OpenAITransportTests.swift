import Foundation
import Testing
@testable import Iriz

@Suite("OpenAI transport and usage")
struct OpenAITransportTests {
    @Test("Every Responses request disables implicit caching and applies the task policy")
    func requestPolicies() throws {
        let observation = Observation(
            source: .screen,
            applicationName: "Safari",
            windowTitle: "Checkout",
            text: "Order confirmed"
        )
        let validation = try jsonObject(OpenAIRequestFactory.validationRequest())
        let interpretation = try jsonObject(OpenAIRequestFactory.interpretationRequest(
            observation: observation,
            imageData: Data([1, 2, 3]),
            outputLanguage: "English"
        ))
        let answer = try jsonObject(OpenAIRequestFactory.answerRequest(
            question: "What happened?",
            candidates: [],
            outputLanguage: "English"
        ))
        let merge = try jsonObject(OpenAIRequestFactory.followUpMergeRequest(
            commitments: [commitment("Prepare"), commitment("Send")],
            subject: nil,
            outputLanguage: "English"
        ))

        for request in [validation, interpretation, answer, merge] {
            #expect(request["store"] as? Bool == false)
            let cache = try #require(request["prompt_cache_options"] as? [String: Any])
            #expect(cache["mode"] as? String == "explicit")
            #expect(cache["ttl"] as? String == "30m")
        }

        #expect(validation["service_tier"] as? String == "default")
        #expect(validation["max_output_tokens"] as? Int == 8)
        #expect(textVerbosity(validation) == "low")
        #expect(interpretation["service_tier"] as? String == "default")
        #expect(interpretation["max_output_tokens"] as? Int == 2_400)
        #expect(textVerbosity(interpretation) == "low")
        #expect(answer["service_tier"] as? String == "default")
        #expect(answer["max_output_tokens"] as? Int == 1_200)
        #expect(textVerbosity(answer) == "low")
        #expect(merge["service_tier"] as? String == "default")
        #expect(merge["max_output_tokens"] as? Int == 1_400)
        #expect(textVerbosity(merge) == "low")
    }

    @Test("Observation cache writes stay disabled until the seven-day qualification threshold")
    func observationCacheBreakpoint() throws {
        let data = try OpenAIRequestFactory.interpretationRequest(
            observation: Observation(source: .screen, text: "Application submitted"),
            imageData: Data([4, 5, 6]),
            outputLanguage: "French"
        )
        let root = try jsonObject(data)
        #expect(root["prompt_cache_key"] == nil)
        let input = try #require(root["input"] as? [[String: Any]])
        let content = try #require(input.first?["content"] as? [[String: Any]])
        #expect(content.count == 3)
        #expect(content[0]["type"] as? String == "input_text")
        #expect(content[0]["prompt_cache_breakpoint"] == nil)
        #expect(content[1]["type"] as? String == "input_text")
        #expect(content[1]["prompt_cache_breakpoint"] == nil)
        #expect(content[2]["type"] as? String == "input_image")

        let text = try #require(root["text"] as? [String: Any])
        let format = try #require(text["format"] as? [String: Any])
        let schema = try #require(format["schema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(properties["explanation"] == nil)
        let commitments = try #require(properties["commitments"] as? [String: Any])
        let commitmentItems = try #require(commitments["items"] as? [String: Any])
        let commitmentProperties = try #require(commitmentItems["properties"] as? [String: Any])
        #expect(commitmentProperties["suggestedReviewAt"] == nil)

        let nonObservation = try jsonObject(OpenAIRequestFactory.validationRequest())
        #expect(nonObservation["prompt_cache_key"] == nil)

        #expect(OpenAIPromptCacheQualification(
            stablePrefixTokens: 1_024,
            cacheReads: 2,
            cacheWrites: 1,
            observationDays: 7
        ).enablesExplicitBreakpoint)
        #expect(!OpenAIPromptCacheQualification(
            stablePrefixTokens: 1_023,
            cacheReads: 20,
            cacheWrites: 1,
            observationDays: 7
        ).enablesExplicitBreakpoint)
        #expect(!OpenAIPromptCacheQualification(
            stablePrefixTokens: 2_000,
            cacheReads: 1,
            cacheWrites: 1,
            observationDays: 7
        ).enablesExplicitBreakpoint)
    }

    @Test("Normal refinements use Flex while completed and critical refinements use Standard")
    func refinementTiers() throws {
        let normal = ActivityEvent(
            startedAt: Date(),
            endedAt: Date(),
            kind: .research,
            status: .observed,
            importance: .important,
            title: "Compared vendors",
            summary: "Vendor notes were reviewed.",
            confidence: 0.8
        )
        var completed = normal
        completed.status = .completed
        var critical = normal
        critical.importance = .critical

        let normalJSON = try jsonObject(OpenAIRequestFactory.refinementRequest(event: normal, outputLanguage: "English"))
        let completedJSON = try jsonObject(OpenAIRequestFactory.refinementRequest(event: completed, outputLanguage: "English"))
        let criticalJSON = try jsonObject(OpenAIRequestFactory.refinementRequest(event: critical, outputLanguage: "English"))

        #expect(normalJSON["service_tier"] as? String == "flex")
        #expect(completedJSON["service_tier"] as? String == "default")
        #expect(criticalJSON["service_tier"] as? String == "default")
        #expect(normalJSON["max_output_tokens"] as? Int == 1_400)
        #expect(textVerbosity(normalJSON) == "low")
        let text = try #require(normalJSON["text"] as? [String: Any])
        let format = try #require(text["format"] as? [String: Any])
        let schema = try #require(format["schema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(properties["kind"] == nil)
        #expect(properties["status"] == nil)
        #expect(properties["urls"] == nil)
        let required = try #require(schema["required"] as? [String])
        #expect(!required.contains("status"))
    }

    @Test("Terra refinement cannot promote an event to completed")
    func terraCannotPromoteCompletion() async throws {
        let responseBody = try responseData(outputObject: [
            "importance": 2,
            "title": "Polished title",
            "summary": "Polished summary",
            "details": "Polished details",
            "entities": ["Iriz"],
            "confidence": 0.95
        ])
        let client = OpenAIClient(dataLoader: { request in
            (responseBody, HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!)
        })
        let source = ActivityEvent(
            startedAt: Date(),
            endedAt: Date(),
            kind: .research,
            status: .observed,
            importance: .important,
            title: "Source",
            summary: "No completion evidence.",
            confidence: 0.8
        )

        let refined = try await client.refine(
            event: source,
            outputLanguage: "English",
            serviceTier: .default,
            apiKey: "fixture-only-key"
        )
        #expect(refined.status == .observed)
        #expect(refined.title == "Polished title")
    }

    @Test("Commitment-only interpretations identify their synthetic event")
    func commitmentFallbackIsExplicit() async throws {
        let responseBody = try responseData(outputObject: [
            "shouldCreateEvent": true,
            "needsOriginalImage": false,
            "languageTag": "en-US",
            "event": NSNull(),
            "commitments": [[
                "operation": "create",
                "existingCommitmentID": NSNull(),
                "owner": "You",
                "action": "Send the proposal",
                "rationale": "Explicit promise",
                "summary": "Proposal follow-up",
                "details": "",
                "explicitDueAt": NSNull(),
                "contextLabel": "Project",
                "area": "work",
                "priorityScore": 7,
                "priorityReason": "Explicit action",
                "dueSource": NSNull(),
                "evidenceStrength": "strong",
                "confidence": 0.9
            ]]
        ])
        let client = OpenAIClient(dataLoader: { request in
            (responseBody, HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!)
        })
        let interpretation = try await client.interpret(
            observation: Observation(source: .screen, text: "I will send the proposal."),
            imageData: nil,
            outputLanguage: "English",
            followUpDetailLevel: .standard,
            knownFollowUpContexts: [],
            followUpCandidates: [],
            knownFollowUpSubjects: [],
            apiKey: "fixture-only-key"
        )

        #expect(interpretation.event != nil)
        #expect(interpretation.eventIsCommitmentFallback)
        #expect(interpretation.commitments.count == 1)
    }

    @Test("Responses metadata decodes cache writes, cache reads, reasoning and incomplete state")
    func responseMetadataDecoding() throws {
        let fixture = Data("""
        {
          "id": "resp_test_123",
          "model": "gpt-5.6-terra-2026-08-01",
          "status": "incomplete",
          "service_tier": "flex",
          "incomplete_details": {"reason": "max_output_tokens"},
          "usage": {
            "input_tokens": 1800,
            "input_tokens_details": {"cached_tokens": 1024, "cache_write_tokens": 512},
            "output_tokens": 1400,
            "output_tokens_details": {"reasoning_tokens": 220},
            "total_tokens": 3200
          }
        }
        """.utf8)

        let metadata = try #require(OpenAIResponseMetadata.decodeIfPresent(from: fixture))
        #expect(metadata.id == "resp_test_123")
        #expect(metadata.model == "gpt-5.6-terra-2026-08-01")
        #expect(metadata.status == "incomplete")
        #expect(metadata.serviceTier == "flex")
        #expect(metadata.incompleteDetails?.reason == "max_output_tokens")
        #expect(metadata.usage?.inputTokens == 1_800)
        #expect(metadata.usage?.cachedInputTokens == 1_024)
        #expect(metadata.usage?.cacheWriteTokens == 512)
        #expect(metadata.usage?.outputTokens == 1_400)
        #expect(metadata.usage?.reasoningTokens == 220)
        #expect(metadata.usage?.totalTokens == 3_200)
    }

    @Test("An output-limit response retries once with the historical ceiling")
    func outputLimitRetry() async throws {
        let probe = OutputLimitRequestProbe()
        let recorder = InMemoryOpenAIUsageRecorder()
        let incomplete = Data("""
        {
          "id": "resp_incomplete",
          "model": "gpt-5.6-terra",
          "status": "incomplete",
          "service_tier": "flex",
          "incomplete_details": {"reason": "max_output_tokens"},
          "usage": {"input_tokens": 10, "output_tokens": 1400, "total_tokens": 1410}
        }
        """.utf8)
        let completed = try responseData(outputObject: [
            "importance": 1,
            "title": "Refined",
            "summary": "Refined summary",
            "details": "",
            "entities": [String](),
            "confidence": 0.8
        ])
        let client = OpenAIClient(
            usageRecorder: recorder,
            dataLoader: { request in
                let attempt = await probe.record(request)
                return (
                    attempt == 1 ? incomplete : completed,
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )
        let event = ActivityEvent(
            startedAt: Date(),
            endedAt: Date(),
            kind: .research,
            status: .observed,
            importance: .important,
            title: "Source",
            summary: "Source summary",
            confidence: 0.8
        )

        _ = try await client.refine(
            event: event,
            outputLanguage: "English",
            serviceTier: .flex,
            apiKey: "fixture-only-key"
        )

        #expect(await probe.outputLimits == [1_400, 2_400])
        let clientIDs = await probe.clientRequestIDs
        #expect(clientIDs.count == 2)
        #expect(Set(clientIDs).count == 2)
        let records = await recorder.records()
        #expect(records.count == 2)
        #expect(Set(records.compactMap(\.logicalRequestID)).count == 1)
        #expect(records.compactMap(\.attemptNumber) == [1, 2])
        #expect(records.first?.incompleteReason == "max_output_tokens")
    }

    @Test("Transport records response metadata and diagnostic headers without request content")
    func transportUsageRecording() async throws {
        let recorder = InMemoryOpenAIUsageRecorder()
        let responseBody = Data("""
        {
          "id": "resp_validation",
          "model": "gpt-5.6-luna-2026-08-01",
          "status": "completed",
          "service_tier": "default",
          "usage": {
            "input_tokens": 32,
            "input_tokens_details": {"cached_tokens": 0, "cache_write_tokens": 0},
            "output_tokens": 3,
            "output_tokens_details": {"reasoning_tokens": 0},
            "total_tokens": 35
          }
        }
        """.utf8)
        let client = OpenAIClient(
            baseURL: URL(string: "https://transport.test/v1")!,
            usageRecorder: recorder,
            dataLoader: { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "x-request-id": "request_123",
                        "openai-processing-ms": "42.5",
                        "x-ratelimit-remaining-requests": "98",
                        "x-ratelimit-reset-tokens": "1s"
                    ]
                )!
                return (responseBody, response)
            }
        )

        try await client.validateAPIKey("fixture-only-key")
        let records = await recorder.records()
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.task == IndicatorAPITask.credentialValidation.rawValue)
        #expect(record.context == IndicatorActivityContext.credentials.rawValue)
        #expect(record.requestedModel == OpenAIModelPolicy.frequentAnalysis)
        #expect(record.logicalRequestID?.hasPrefix("credential-validation:") == true)
        #expect(record.attemptNumber == 1)
        #expect(record.responseID == "resp_validation")
        #expect(record.actualModel == "gpt-5.6-luna-2026-08-01")
        #expect(record.requestedServiceTier == "default")
        #expect(record.actualServiceTier == "default")
        #expect(record.inputTokens == 32)
        #expect(record.outputTokens == 3)
        #expect(record.requestID == "request_123")
        #expect(record.processingMilliseconds == 42.5)
        #expect(record.rateLimits["x-ratelimit-remaining-requests"] == "98")
        #expect(record.rateLimits["x-ratelimit-reset-tokens"] == "1s")
        #expect(record.outcome == .success)
        #expect(record.errorKind == nil)
    }

    @Test("Durable queue attempts propagate into request telemetry")
    func durableAttemptTelemetry() async throws {
        let recorder = InMemoryOpenAIUsageRecorder()
        let responseBody = Data("""
        {
          "id": "resp_retry",
          "model": "gpt-5.6-luna-2026-08-01",
          "status": "completed",
          "service_tier": "default",
          "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}
        }
        """.utf8)
        let client = OpenAIClient(
            baseURL: URL(string: "https://transport.test/v1")!,
            usageRecorder: recorder,
            dataLoader: { request in
                (
                    responseBody,
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )

        try await OpenAIDurableAttemptContext.$number.withValue(3) {
            try await client.validateAPIKey("fixture-only-key")
        }

        let records = await recorder.records()
        let record = try #require(records.first)
        #expect(record.attemptNumber == 3)
    }

    @Test("Separate validation invocations receive distinct logical and client identifiers")
    func requestIdentifiers() async throws {
        let headers = ClientRequestHeaderProbe()
        let recorder = InMemoryOpenAIUsageRecorder()
        let responseBody = Data("""
        {
          "id": "resp_validation",
          "model": "gpt-5.6-luna-2026-08-01",
          "status": "completed",
          "service_tier": "default",
          "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}
        }
        """.utf8)
        let client = OpenAIClient(
            baseURL: URL(string: "https://transport.test/v1")!,
            usageRecorder: recorder,
            dataLoader: { request in
                await headers.receive(request.value(forHTTPHeaderField: "X-Client-Request-Id"))
                return (
                    responseBody,
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
        )

        try await client.validateAPIKey("fixture-only-key")
        try await client.validateAPIKey("fixture-only-key")

        let values = await headers.values
        let records = await recorder.records()
        #expect(values.count == 2)
        #expect(values.allSatisfy { UUID(uuidString: $0) != nil })
        #expect(Set(values).count == 2)
        #expect(Set(records.compactMap(\.logicalRequestID)).count == 2)
        #expect(records.allSatisfy { $0.logicalRequestID?.hasPrefix("credential-validation:") == true })
        #expect(Set(records.map { $0.attemptID.uuidString }) == Set(values))
    }

    @Test("Ask and merge invocations use unique logical identifiers while refinement revisions stay stable")
    func logicalRequestIdentityScope() async throws {
        let answerRecorder = InMemoryOpenAIUsageRecorder()
        let answerBody = try responseData(outputObject: ["answer": "No matching evidence was found", "eventIDs": []])
        let answerClient = OpenAIClient(
            usageRecorder: answerRecorder,
            dataLoader: { request in
                (answerBody, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )
        _ = try await answerClient.answer(
            question: "What happened?",
            candidates: [],
            conversationContext: [],
            outputLanguage: "English",
            apiKey: "fixture-only-key"
        )
        _ = try await answerClient.answer(
            question: "What happened?",
            candidates: [],
            conversationContext: [],
            outputLanguage: "English",
            apiKey: "fixture-only-key"
        )
        #expect(Set(await answerRecorder.records().compactMap(\.logicalRequestID)).count == 2)

        let mergeRecorder = InMemoryOpenAIUsageRecorder()
        let mergeBody = try responseData(outputObject: [
            "action": "Send proposal",
            "summary": "Prepare and send the proposal.",
            "details": "",
            "contextLabel": "Client",
            "area": FollowUpArea.work.rawValue,
            "priorityScore": 5,
            "priorityReason": "Explicit request",
            "dueAt": NSNull(),
            "dueSource": NSNull(),
            "confidence": 0.9,
            "relationship": "related",
            "relationshipReason": "Same deliverable"
        ])
        let mergeClient = OpenAIClient(
            usageRecorder: mergeRecorder,
            dataLoader: { request in
                (mergeBody, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )
        let commitments = [commitment("Prepare proposal"), commitment("Send proposal")]
        _ = try await mergeClient.mergeFollowUps(
            commitments,
            subject: nil,
            outputLanguage: "English",
            apiKey: "fixture-only-key"
        )
        _ = try await mergeClient.mergeFollowUps(
            commitments,
            subject: nil,
            outputLanguage: "English",
            apiKey: "fixture-only-key"
        )
        #expect(Set(await mergeRecorder.records().compactMap(\.logicalRequestID)).count == 2)

        let refinementRecorder = InMemoryOpenAIUsageRecorder()
        let refinementBody = try responseData(outputObject: [
            "importance": 1,
            "title": "Refined",
            "summary": "Refined summary",
            "details": "",
            "entities": [],
            "confidence": 0.8
        ])
        let refinementClient = OpenAIClient(
            usageRecorder: refinementRecorder,
            dataLoader: { request in
                (refinementBody, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )
        var event = ActivityEvent(
            startedAt: Date(),
            endedAt: Date(),
            kind: .research,
            status: .observed,
            importance: .normal,
            title: "Source",
            summary: "Source summary",
            confidence: 0.8
        )
        let originalRevision = event.updatedAt
        _ = try await refinementClient.refine(
            event: event,
            outputLanguage: "English",
            serviceTier: .default,
            apiKey: "fixture-only-key"
        )
        _ = try await refinementClient.refine(
            event: event,
            outputLanguage: "English",
            serviceTier: .default,
            apiKey: "fixture-only-key"
        )
        event.updatedAt = originalRevision.addingTimeInterval(1)
        _ = try await refinementClient.refine(
            event: event,
            outputLanguage: "English",
            serviceTier: .default,
            apiKey: "fixture-only-key"
        )
        let refinementIDs = await refinementRecorder.records().compactMap(\.logicalRequestID)
        #expect(refinementIDs.count == 3)
        #expect(refinementIDs[0] == refinementIDs[1])
        #expect(refinementIDs[1] != refinementIDs[2])
    }

    @Test("HTTP failures never expose the provider error message in errors or telemetry")
    func sanitizedHTTPFailure() async throws {
        let recorder = InMemoryOpenAIUsageRecorder()
        let client = OpenAIClient(
            baseURL: URL(string: "https://transport.test/v1")!,
            usageRecorder: recorder,
            dataLoader: { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "30", "x-request-id": "request_failure_123"]
                )!
                let body = Data("""
                {"error":{"message":"sensitive input fragment must never escape","type":"rate_limit_error","code":"resource_unavailable"}}
                """.utf8)
                return (body, response)
            }
        )

        do {
            try await client.validateAPIKey("fixture-only-key")
            Issue.record("Expected a 429 error")
        } catch let error as OpenAIClientError {
            #expect(error.errorDescription?.contains("sensitive input fragment") == false)
            #expect(error.errorDescription?.contains("temporarily unavailable") == true)
            guard case .requestFailed(let failure) = error else {
                Issue.record("Expected structured HTTP failure metadata")
                return
            }
            #expect(failure.status == 429)
            #expect(failure.errorKind == "resource_unavailable")
            #expect(failure.requestID == "request_failure_123")
            #expect(failure.retryAfter == "30")
            #expect(failure.retryAfterSeconds == 30)
        }

        let records = await recorder.records()
        let record = try #require(records.first)
        #expect(record.outcome == .failure)
        #expect(record.httpStatus == 429)
        #expect(record.retryAfter == "30")
        #expect(record.errorKind == "resource_unavailable")
        #expect(record.inputTokens == nil)
        #expect(record.responseStatus == nil)
    }

    @Test("Structured HTTP failures preserve credential detection and Retry-After")
    func structuredHTTPFailurePolicy() {
        let credentialFailure = OpenAIHTTPFailure(
            status: 401,
            errorKind: "invalid_api_key",
            requestID: "request_auth",
            retryAfter: nil
        )
        let limitedFailure = OpenAIHTTPFailure(
            status: 429,
            errorKind: "rate_limit_exceeded",
            requestID: "request_limit",
            retryAfter: "12.5"
        )

        #expect(OpenAIClientError.requestFailed(credentialFailure).isInvalidCredential)
        #expect(!OpenAIClientError.requestFailed(limitedFailure).isInvalidCredential)
        #expect(limitedFailure.retryAfterSeconds == 12.5)
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func textVerbosity(_ object: [String: Any]) -> String? {
        (object["text"] as? [String: Any])?["verbosity"] as? String
    }

    private func responseData(outputObject: [String: Any]) throws -> Data {
        let outputText = String(decoding: try JSONSerialization.data(
            withJSONObject: outputObject,
            options: [.sortedKeys]
        ), as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: [
            "id": "resp_fixture",
            "model": "fixture-model",
            "status": "completed",
            "service_tier": "default",
            "output": [[
                "content": [["type": "output_text", "text": outputText]]
            ]],
            "usage": ["input_tokens": 10, "output_tokens": 10, "total_tokens": 20]
        ])
    }

    private func commitment(_ action: String) -> Commitment {
        Commitment(
            eventID: UUID(),
            owner: "You",
            action: action,
            confidence: 0.9,
            state: .needsAttention
        )
    }
}

private actor ClientRequestHeaderProbe {
    private(set) var values: [String] = []

    func receive(_ value: String?) {
        if let value { values.append(value) }
    }
}

private actor OutputLimitRequestProbe {
    private(set) var outputLimits: [Int] = []
    private(set) var clientRequestIDs: [String] = []

    func record(_ request: URLRequest) -> Int {
        if let body = request.httpBody,
           let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let limit = object["max_output_tokens"] as? Int {
            outputLimits.append(limit)
        }
        if let identifier = request.value(forHTTPHeaderField: "X-Client-Request-Id") {
            clientRequestIDs.append(identifier)
        }
        return outputLimits.count
    }
}
