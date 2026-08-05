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

    @Test("Only observation requests write the stable explicit prompt cache prefix")
    func observationCacheBreakpoint() throws {
        let data = try OpenAIRequestFactory.interpretationRequest(
            observation: Observation(source: .screen, text: "Application submitted"),
            imageData: Data([4, 5, 6]),
            outputLanguage: "French"
        )
        let root = try jsonObject(data)
        #expect(root["prompt_cache_key"] as? String == "iriz:observation:prompt-v2-schema-v2")
        let input = try #require(root["input"] as? [[String: Any]])
        let content = try #require(input.first?["content"] as? [[String: Any]])
        #expect(content.count == 3)
        #expect(content[0]["type"] as? String == "input_text")
        let breakpoint = try #require(content[0]["prompt_cache_breakpoint"] as? [String: Any])
        #expect(breakpoint["mode"] as? String == "explicit")
        #expect(content[1]["type"] as? String == "input_text")
        #expect(content[1]["prompt_cache_breakpoint"] == nil)
        #expect(content[2]["type"] as? String == "input_image")

        let nonObservation = try jsonObject(OpenAIRequestFactory.validationRequest())
        #expect(nonObservation["prompt_cache_key"] == nil)
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
            summary: "Vendor notes were reviewed."
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
        #expect(record.requestedModel == OpenAIModelPolicy.frequentAnalysis)
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
                    headerFields: ["Retry-After": "30"]
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
        }

        let record = try #require(await recorder.records().first)
        #expect(record.outcome == .failure)
        #expect(record.httpStatus == 429)
        #expect(record.retryAfter == "30")
        #expect(record.errorKind == "resource_unavailable")
        #expect(record.inputTokens == nil)
        #expect(record.responseStatus == nil)
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func textVerbosity(_ object: [String: Any]) -> String? {
        (object["text"] as? [String: Any])?["verbosity"] as? String
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
