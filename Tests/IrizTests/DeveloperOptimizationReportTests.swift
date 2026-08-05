import Foundation
import Testing
@testable import Iriz

@Suite("Developer optimization reporting")
struct DeveloperOptimizationReportTests {
    @Test("Apple qualification rejects mixed fingerprints and excludes cache hits from warm p95")
    func uniqueFingerprintAndUncachedLatency() throws {
        let first = fingerprint(minor: 5)
        let second = fingerprint(minor: 6)
        let mixed = [
            shadowRecord(fingerprint: first, latency: 800),
            shadowRecord(fingerprint: second, latency: 700)
        ]

        do {
            _ = try AppleQualificationEvaluator.report(for: mixed)
            Issue.record("A mixed-fingerprint qualification must be rejected")
        } catch let error as AppleQualificationEvaluationError {
            #expect(error == .mixedModelFingerprints)
        }

        let records = [
            shadowRecord(fingerprint: first, latency: 200),
            shadowRecord(fingerprint: first, latency: 900),
            shadowRecord(fingerprint: first, latency: 5, fromCache: true),
            shadowRecord(fingerprint: nil, latency: 1_400, generated: true, critical: true)
        ]
        let report = try AppleQualificationEvaluator.report(for: records)
        #expect(report.modelFingerprint == first)
        #expect(report.observationCount == 3)
        #expect(report.gateDecisionCount == 3)
        #expect(report.structuredGenerationCount == 2)
        #expect(report.cacheHitCount == 1)
        #expect(report.warmLatencyP95Milliseconds == 900)
        #expect(report.criticalCaseCount == 0)
    }

    @Test("Older Shadow records decode as uncached")
    func backwardCompatibleFromCacheDecode() throws {
        let original = shadowRecord(fingerprint: fingerprint(), latency: 500)
        let encoded = try JSONEncoder().encode(original)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "fromCache")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AppleShadowQualificationRecord.self, from: legacy)
        #expect(!decoded.fromCache)
        #expect(decoded.modelFingerprint == original.modelFingerprint)
        #expect(decoded.localEventOutcome == .notAttempted)
        #expect(decoded.localEventLatencyMilliseconds == nil)
        #expect(decoded.localEventCloudCompatible == nil)
        #expect(!decoded.localEventCriticalMismatch)
        #expect(!decoded.localEventSafetyViolation)
    }

    @Test("Older usage records decode without an attempt number")
    func backwardCompatibleUsageAttemptDecode() throws {
        let record = usageRecord(startedAt: Date(timeIntervalSince1970: 2_000_000_000), logicalID: "legacy")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        object.removeValue(forKey: "attemptNumber")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(OpenAIUsageRecord.self, from: legacy)
        #expect(decoded.attemptNumber == nil)
    }

    @Test("JSON and Markdown reports contain only aggregate diagnostics and label costs as estimates")
    func contentFreeVersionedExports() throws {
        let now = Date(timeIntervalSince1970: 2_000_500_000)
        let observationID = UUID()
        let usage = usageRecord(startedAt: now, logicalID: "private-logical-request")
        let shadow = AppleShadowQualificationRecord(
            observationID: observationID,
            occurredAt: now,
            modelFingerprint: fingerprint(),
            verdict: .clearlyEmpty,
            routeReason: .shadowMode,
            localLatencyMilliseconds: 650,
            generationAttempted: true,
            structuredOutputValid: true,
            cloudMeaningful: true,
            isCriticalCase: false,
            exampleText: "private disagreement content"
        )
        let optimization = OptimizationTelemetryRecord(
            occurredAt: now,
            metric: .captureQueueDropped,
            reason: .queueCapacity,
            source: .screen,
            occurrenceCount: 2,
            latencyMilliseconds: 40,
            queueDepth: 3,
            isMeeting: false
        )
        let report = DeveloperOptimizationReportBuilder.build(
            generatedAt: now,
            detailWindowStart: now.addingTimeInterval(-30 * 86_400),
            aggregateWindowStart: now.addingTimeInterval(-90 * 86_400),
            usageRecords: [usage],
            usageDailyAggregates: [OpenAIUsageDailyAggregate(
                day: "2033-05-18",
                priceVersion: "historical-price-v1",
                requestCount: 1,
                inputTokens: 1_000,
                cachedInputTokens: 100,
                cacheWriteTokens: 0,
                outputTokens: 200,
                reasoningTokens: 0,
                totalTokens: 1_200,
                estimatedCostUSD: 0.0021
            )],
            optimizationRecords: [optimization],
            optimizationDailyAggregates: [],
            appleShadowRecords: [shadow]
        )

        #expect(report.pricing.priceVersion == OpenAICostEstimator.priceVersion)
        #expect(!report.pricing.isExact)
        #expect(report.openAI.dailyAggregates.first?.priceVersion == "historical-price-v1")
        #expect(report.openAI.dailyAggregates.first?.isExactCost == false)
        #expect(report.openAI.pricedDetailRequestCount == 1)
        #expect(report.openAI.unpricedDetailRequestCount == 0)
        #expect(report.openAI.pricingCoverageRate == 1)
        #expect(report.appleShadow.count == 1)

        let json = String(decoding: try DeveloperOptimizationReportExporter.data(for: report, format: .json), as: UTF8.self)
        let markdown = String(decoding: try DeveloperOptimizationReportExporter.data(for: report, format: .markdown), as: UTF8.self)
        for export in [json, markdown] {
            #expect(export.contains(OpenAICostEstimator.priceVersion))
            #expect(!export.contains("private disagreement content"))
            #expect(!export.contains("private-logical-request"))
            #expect(!export.contains(observationID.uuidString))
            #expect(!export.contains("exampleText"))
        }
        #expect(json.contains("\"isExact\" : false"))
        #expect(markdown.contains("not an invoice or exact billed amount"))
        #expect(markdown.contains("historical-price-v1"))
    }

    @Test("Transcription estimates prefer token usage and report duration fallback, unpriced coverage, and retry cost")
    func transcriptionAndRetryCostCoverage() throws {
        let now = Date(timeIntervalSince1970: 2_000_600_000)
        let tokenTranscription = usageRecord(
            startedAt: now,
            logicalID: "transcription-token",
            requestedModel: "gpt-4o-transcribe",
            actualModel: "gpt-4o-transcribe-2026-08-01",
            inputTokens: 1_000,
            outputTokens: 500,
            audioDurationSeconds: 60
        )
        let durationTranscription = usageRecord(
            startedAt: now.addingTimeInterval(1),
            logicalID: "transcription-duration",
            requestedModel: "gpt-4o-transcribe-diarize",
            actualModel: nil,
            inputTokens: nil,
            outputTokens: nil,
            audioDurationSeconds: 120
        )
        let gptTranscribe = usageRecord(
            startedAt: now.addingTimeInterval(1.5),
            logicalID: "gpt-transcribe-duration",
            requestedModel: "gpt-transcribe",
            actualModel: nil,
            inputTokens: nil,
            outputTokens: nil,
            audioDurationSeconds: 60
        )
        let first = usageRecord(startedAt: now.addingTimeInterval(2), logicalID: "retry-group")
        let retry = usageRecord(
            startedAt: now.addingTimeInterval(3),
            logicalID: "retry-group",
            attemptNumber: 2
        )
        let unknown = usageRecord(
            startedAt: now.addingTimeInterval(4),
            logicalID: "unknown",
            requestedModel: "future-unpriced-model",
            actualModel: nil,
            inputTokens: 100,
            outputTokens: 20
        )

        let tokenEstimate = try #require(OpenAICostEstimator.estimate(for: tokenTranscription))
        #expect(tokenEstimate.basis == .tokenTable)
        #expect(abs(tokenEstimate.amountUSD - 0.0075) < 0.000_000_1)
        let durationEstimate = try #require(OpenAICostEstimator.estimate(for: durationTranscription))
        #expect(durationEstimate.basis == .estimatedAudioDuration)
        #expect(abs(durationEstimate.amountUSD - 0.012) < 0.000_000_1)
        let gptTranscribeEstimate = try #require(OpenAICostEstimator.estimate(for: gptTranscribe))
        #expect(gptTranscribeEstimate.basis == .estimatedAudioDuration)
        #expect(abs(gptTranscribeEstimate.amountUSD - 0.0045) < 0.000_000_1)
        #expect(OpenAICostEstimator.estimate(for: unknown) == nil)

        let report = DeveloperOptimizationReportBuilder.build(
            generatedAt: now,
            detailWindowStart: now.addingTimeInterval(-30 * 86_400),
            aggregateWindowStart: now.addingTimeInterval(-90 * 86_400),
            usageRecords: [tokenTranscription, durationTranscription, first, retry, unknown],
            usageDailyAggregates: [],
            optimizationRecords: [],
            optimizationDailyAggregates: [],
            appleShadowRecords: []
        )
        #expect(report.openAI.detailRequestCount == 5)
        #expect(report.openAI.pricedDetailRequestCount == 4)
        #expect(report.openAI.unpricedDetailRequestCount == 1)
        #expect(abs(report.openAI.pricingCoverageRate - 0.8) < 0.000_000_1)
        #expect(report.openAI.durationEstimatedRequestCount == 1)
        #expect(report.openAI.retryRequestCount == 1)
        #expect(report.openAI.retryEstimatedCostUSD > 0)
        #expect(report.openAI.retryCostShare > 0)
    }

    @Test("Optimization latency p95 uses the nearest-rank percentile")
    func optimizationLatencyP95() throws {
        let now = Date(timeIntervalSince1970: 2_000_650_000)
        let records = (1...20).map { seconds in
            OptimizationTelemetryRecord(
                occurredAt: now.addingTimeInterval(TimeInterval(seconds)),
                metric: .eventVisible,
                reason: .normalEvent,
                source: .screen,
                latencyMilliseconds: seconds * 1_000,
                isMeeting: false
            )
        }
        let report = DeveloperOptimizationReportBuilder.build(
            generatedAt: now,
            detailWindowStart: now.addingTimeInterval(-30 * 86_400),
            aggregateWindowStart: now.addingTimeInterval(-90 * 86_400),
            usageRecords: [],
            usageDailyAggregates: [],
            optimizationRecords: records,
            optimizationDailyAggregates: [],
            appleShadowRecords: []
        )

        let bucket = try #require(report.optimization.buckets.first)
        #expect(bucket.averageLatencyMilliseconds == 10_500)
        #expect(bucket.p95LatencyMilliseconds == 19_000)
    }

    @Test("Unfingerprinted Apple records remain unassigned and never affect qualification")
    func unfingerprintedShadowRecordsStayUnassigned() throws {
        let now = Date(timeIntervalSince1970: 2_000_700_000)
        let assigned = shadowRecord(fingerprint: fingerprint(), latency: 500)
        let unassigned = shadowRecord(fingerprint: nil, latency: 0, generated: false, critical: true)
        let report = DeveloperOptimizationReportBuilder.build(
            generatedAt: now,
            detailWindowStart: now.addingTimeInterval(-30 * 86_400),
            aggregateWindowStart: now.addingTimeInterval(-90 * 86_400),
            usageRecords: [],
            usageDailyAggregates: [],
            optimizationRecords: [],
            optimizationDailyAggregates: [],
            appleShadowRecords: [assigned, unassigned]
        )

        let qualification = try #require(report.appleShadow.first)
        #expect(report.appleShadow.count == 1)
        #expect(qualification.observationCount == 1)
        #expect(qualification.criticalCaseCount == 0)
        #expect(report.unassignedAppleShadowRecordCount == 1)
    }

    @Test("Manual exporter writes a content-free report")
    func manualWrite() throws {
        let now = Date(timeIntervalSince1970: 2_000_500_000)
        let report = DeveloperOptimizationReportBuilder.build(
            generatedAt: now,
            detailWindowStart: now.addingTimeInterval(-30 * 86_400),
            aggregateWindowStart: now.addingTimeInterval(-90 * 86_400),
            usageRecords: [],
            usageDailyAggregates: [],
            optimizationRecords: [],
            optimizationDailyAggregates: [],
            appleShadowRecords: []
        )
        let url = URL(fileURLWithPath: "/private/tmp/IrizDeveloperReport-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try DeveloperOptimizationReportExporter.write(report, format: .json, to: url)
        let saved = try Data(contentsOf: url)
        #expect(!saved.isEmpty)
        #expect(String(decoding: saved, as: UTF8.self).contains(DeveloperOptimizationReport.currentSchemaVersion))
    }

    private func fingerprint(minor: Int = 5) -> AppleModelFingerprint {
        AppleModelFingerprint(
            operatingSystemMajor: 26,
            operatingSystemMinor: minor,
            localeIdentifier: "fr-FR",
            promptVersion: "local-gate-v1",
            schemaVersion: "local-gate-verdict-v1"
        )
    }

    private func shadowRecord(
        fingerprint: AppleModelFingerprint?,
        latency: Int,
        fromCache: Bool = false,
        generated: Bool = true,
        critical: Bool = false
    ) -> AppleShadowQualificationRecord {
        AppleShadowQualificationRecord(
            observationID: UUID(),
            modelFingerprint: fingerprint,
            verdict: generated ? .meaningful : nil,
            routeReason: generated ? .shadowMode : .highRiskSignal,
            localLatencyMilliseconds: latency,
            generationAttempted: generated,
            fromCache: fromCache,
            structuredOutputValid: generated,
            cloudMeaningful: generated,
            isCriticalCase: critical,
            exampleText: nil
        )
    }

    private func usageRecord(
        startedAt: Date,
        logicalID: String,
        attemptNumber: Int = 1,
        requestedModel: String = OpenAIModelPolicy.frequentAnalysis,
        actualModel: String? = OpenAIModelPolicy.frequentAnalysis,
        inputTokens: Int? = 1_000,
        outputTokens: Int? = 200,
        audioDurationSeconds: TimeInterval? = nil
    ) -> OpenAIUsageRecord {
        OpenAIUsageRecord(
            logicalRequestID: logicalID,
            attemptID: UUID(),
            attemptNumber: attemptNumber,
            startedAt: startedAt,
            durationSeconds: 0.4,
            task: OpenAITask.observationClassification.rawValue,
            context: IndicatorActivityContext.screen.rawValue,
            requestedModel: requestedModel,
            responseID: "private-response-id",
            actualModel: actualModel,
            requestedServiceTier: OpenAIServiceTier.default.rawValue,
            actualServiceTier: OpenAIServiceTier.default.rawValue,
            reasoningEffort: OpenAIReasoningEffort.none.rawValue,
            maxOutputTokens: 2_400,
            outcome: .success,
            httpStatus: 200,
            responseStatus: "completed",
            incompleteReason: nil,
            usage: OpenAIResponseUsage(
                inputTokens: inputTokens,
                cachedInputTokens: requestedModel == OpenAIModelPolicy.frequentAnalysis ? 100 : nil,
                cacheWriteTokens: 0,
                outputTokens: outputTokens,
                reasoningTokens: 0,
                totalTokens: (inputTokens ?? 0) + (outputTokens ?? 0)
            ),
            requestBytes: 2_000,
            responseBytes: 500,
            imageCount: 1,
            audioDurationSeconds: audioDurationSeconds,
            headers: nil,
            errorKind: nil
        )
    }
}

@Suite("Deterministic optimization corpus replay")
struct OptimizationCorpusReplayTests {
    @Test("The same corpus replays through Legacy, Shadow, and Adaptive without cloud requests")
    @available(macOS 26.0, *)
    func phaseReplay() async {
        let fingerprint = AppleModelFingerprint(
            operatingSystemMajor: 26,
            operatingSystemMinor: 5,
            localeIdentifier: "en-US",
            promptVersion: SystemFoundationModelGateProvider.promptVersion,
            schemaVersion: SystemFoundationModelGateProvider.schemaVersion
        )
        let registry = AppleQualificationRegistry(profiles: [
            AppleQualificationProfile(
                fingerprint: fingerprint,
                gateEnabled: true,
                qualifiedAt: Date(timeIntervalSince1970: 1_000)
            )
        ])
        let runner = OptimizationCorpusReplayRunner(
            registry: registry,
            providerFactory: { ReplayGateProvider(fingerprint: fingerprint) }
        )
        let corpus = [
            OptimizationReplayCorpusCase(
                input: LocalGateInput(
                    source: .screen,
                    applicationName: "Browser",
                    windowTitle: "Navigation",
                    text: "Routine navigation through generic appearance preferences.",
                    languageTag: "en-US"
                ),
                referenceCloudMeaningful: false,
                isCriticalCase: false
            ),
            OptimizationReplayCorpusCase(
                input: LocalGateInput(
                    source: .screen,
                    applicationName: "Editor",
                    windowTitle: "Research",
                    text: "Meaningful research compares implementation architecture options.",
                    languageTag: "en-US"
                ),
                referenceCloudMeaningful: true,
                isCriticalCase: false
            )
        ]

        let report = await runner.replay(corpus)
        #expect(report.corpusCount == 2)
        #expect(report.phases.map(\.phase) == [.legacy, .shadow, .adaptive])
        let legacy = report.phases[0]
        let shadow = report.phases[1]
        let adaptive = report.phases[2]
        #expect(legacy.cloudRouteCount == 2)
        #expect(legacy.suppressedCloudCount == 0)
        #expect(shadow.cloudRouteCount == 2)
        #expect(shadow.verdictCounts == ["clearlyEmpty": 1, "meaningful": 1])
        #expect(adaptive.cloudRouteCount == 1)
        #expect(adaptive.suppressedCloudCount == 1)
        #expect(adaptive.falseRejectionCount == 0)
        #expect(adaptive.cacheHitCount == 0)
    }
}

@available(macOS 26.0, *)
private actor ReplayGateProvider: LocalGateModelProviding {
    let fingerprint: AppleModelFingerprint

    init(fingerprint: AppleModelFingerprint) {
        self.fingerprint = fingerprint
    }

    func environment(localeIdentifier: String) -> LocalGateModelEnvironment {
        LocalGateModelEnvironment(availability: .available, fingerprint: fingerprint)
    }

    func prewarm() {}

    func classify(prompt: String) -> LocalGateVerdict {
        prompt.localizedCaseInsensitiveContains("routine navigation") ? .clearlyEmpty : .meaningful
    }
}
