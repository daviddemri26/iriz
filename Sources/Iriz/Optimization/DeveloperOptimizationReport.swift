import Foundation

struct DeveloperOptimizationReport: Codable, Equatable, Sendable {
    static let currentSchemaVersion = "iriz-optimization-report-v5"

    let schemaVersion: String
    let generatedAt: Date
    let detailWindowStart: Date
    let aggregateWindowStart: Date
    let pricing: DeveloperPricingDisclosure
    let openAI: DeveloperOpenAIReport
    let optimization: DeveloperOptimizationTelemetryReport
    let appleShadow: [DeveloperAppleQualificationSummary]
    let unassignedAppleShadowRecordCount: Int
}

struct DeveloperPricingDisclosure: Codable, Equatable, Sendable {
    let priceVersion: String
    let currency: String
    let isExact: Bool
    let disclosure: String

    static let current = DeveloperPricingDisclosure(
        priceVersion: OpenAICostEstimator.priceVersion,
        currency: "USD",
        isExact: false,
        disclosure: "Estimated from a versioned price table; transcription falls back to an estimated duration rate when token usage is absent. This is not an OpenAI invoice or exact billed cost."
    )
}

struct DeveloperOpenAIReport: Codable, Equatable, Sendable {
    let detailRequestCount: Int
    let pricedDetailRequestCount: Int
    let unpricedDetailRequestCount: Int
    let pricingCoverageRate: Double
    let durationEstimatedRequestCount: Int
    let detailEstimatedCostUSD: Double
    let retryRequestCount: Int
    let retryEstimatedCostUSD: Double
    let retryCostShare: Double
    let buckets: [DeveloperOpenAIUsageBucket]
    let dailyAggregates: [DeveloperOpenAIDailyUsage]
}

struct DeveloperOpenAIUsageBucket: Codable, Equatable, Sendable {
    let task: String
    let requestedModel: String
    let actualModel: String?
    let requestedServiceTier: String
    let actualServiceTier: String?
    let reasoningEffort: String?
    let maxOutputTokens: Int?
    let requestCount: Int
    let successCount: Int
    let failureCount: Int
    let cancelledCount: Int
    let inputTokens: Int
    let cachedInputTokens: Int
    let cacheWriteTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let totalTokens: Int
    let estimatedCostUSD: Double
}

struct DeveloperOpenAIDailyUsage: Codable, Equatable, Sendable {
    let day: String
    let priceVersion: String
    let isExactCost: Bool
    let requestCount: Int
    let inputTokens: Int
    let cachedInputTokens: Int
    let cacheWriteTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let totalTokens: Int
    let estimatedCostUSD: Double
}

struct DeveloperOptimizationTelemetryReport: Codable, Equatable, Sendable {
    let detailRecordCount: Int
    let buckets: [DeveloperOptimizationTelemetryBucket]
    let dailyAggregates: [OptimizationTelemetryDailyAggregate]
}

struct DeveloperOptimizationTelemetryBucket: Codable, Equatable, Sendable {
    let metric: OptimizationTelemetryMetric
    let reason: OptimizationTelemetryReason?
    let source: OptimizationTelemetrySource?
    let isMeeting: Bool?
    let recordCount: Int
    let occurrenceCount: Int
    let averageLatencyMilliseconds: Int?
    let p95LatencyMilliseconds: Int?
    let maximumQueueDepth: Int?
}

struct DeveloperAppleQualificationSummary: Codable, Equatable, Sendable {
    let fingerprint: AppleModelFingerprint
    let observationCount: Int
    let gateDecisionCount: Int
    let meaningfulObservationCount: Int
    let criticalCaseCount: Int
    let criticalBypassViolationCount: Int
    let falseRejectionCount: Int
    let criticalFalseRejectionCount: Int
    let falseRejectionRate: Double
    let structuredGenerationCount: Int
    let validStructuredGenerationCount: Int
    let structuredValidityRate: Double
    let cacheHitCount: Int
    let warmUncachedLatencyP95Milliseconds: Int?
    let qualifiesGate: Bool
    let localEventAttemptCount: Int
    let validLocalEventGenerationCount: Int
    let localEventValidityRate: Double
    let localEventCloudCompatibleCount: Int
    let localEventCloudCompatibilityRate: Double
    let localEventCriticalMismatchCount: Int
    let localEventSafetyViolationCount: Int
    let localEventLatencyP95Milliseconds: Int?
    let qualifiesLocalEvents: Bool

    init(_ value: AppleQualificationReport) {
        fingerprint = value.modelFingerprint
        observationCount = value.observationCount
        gateDecisionCount = value.gateDecisionCount
        meaningfulObservationCount = value.meaningfulObservationCount
        criticalCaseCount = value.criticalCaseCount
        criticalBypassViolationCount = value.criticalBypassViolationCount
        falseRejectionCount = value.falseRejectionCount
        criticalFalseRejectionCount = value.criticalFalseRejectionCount
        falseRejectionRate = value.falseRejectionRate
        structuredGenerationCount = value.structuredGenerationCount
        validStructuredGenerationCount = value.validStructuredGenerationCount
        structuredValidityRate = value.structuredValidityRate
        cacheHitCount = value.cacheHitCount
        warmUncachedLatencyP95Milliseconds = value.warmLatencyP95Milliseconds
        qualifiesGate = value.qualifiesGate
        localEventAttemptCount = value.localEventAttemptCount
        validLocalEventGenerationCount = value.validLocalEventGenerationCount
        localEventValidityRate = value.localEventValidityRate
        localEventCloudCompatibleCount = value.localEventCloudCompatibleCount
        localEventCloudCompatibilityRate = value.localEventCloudCompatibilityRate
        localEventCriticalMismatchCount = value.localEventCriticalMismatchCount
        localEventSafetyViolationCount = value.localEventSafetyViolationCount
        localEventLatencyP95Milliseconds = value.localEventLatencyP95Milliseconds
        qualifiesLocalEvents = value.qualifiesLocalEvents
    }
}

enum DeveloperOptimizationReportBuilder {
    private struct OpenAIBucketKey: Hashable {
        let task: String
        let requestedModel: String
        let actualModel: String?
        let requestedServiceTier: String
        let actualServiceTier: String?
        let reasoningEffort: String?
        let maxOutputTokens: Int?
    }

    private struct OptimizationBucketKey: Hashable {
        let metric: OptimizationTelemetryMetric
        let reason: OptimizationTelemetryReason?
        let source: OptimizationTelemetrySource?
        let isMeeting: Bool?
    }

    static func build(
        generatedAt: Date = Date(),
        detailWindowStart: Date,
        aggregateWindowStart: Date,
        usageRecords: [OpenAIUsageRecord],
        usageDailyAggregates: [OpenAIUsageDailyAggregate],
        optimizationRecords: [OptimizationTelemetryRecord],
        optimizationDailyAggregates: [OptimizationTelemetryDailyAggregate],
        appleShadowRecords: [AppleShadowQualificationRecord]
    ) -> DeveloperOptimizationReport {
        let groupedUsage: [OpenAIBucketKey: [OpenAIUsageRecord]] = Dictionary(
            grouping: usageRecords,
            by: openAIBucketKey
        )
        let openAIBuckets: [DeveloperOpenAIUsageBucket] = groupedUsage.map { entry in
            makeOpenAIBucket(key: entry.key, records: entry.value)
        }.sorted {
            ($0.task, $0.requestedModel, $0.requestedServiceTier)
                < ($1.task, $1.requestedModel, $1.requestedServiceTier)
        }

        let groupedOptimization: [OptimizationBucketKey: [OptimizationTelemetryRecord]] = Dictionary(
            grouping: optimizationRecords,
            by: optimizationBucketKey
        )
        let optimizationBuckets: [DeveloperOptimizationTelemetryBucket] = groupedOptimization.map { entry in
            makeOptimizationBucket(key: entry.key, records: entry.value)
        }.sorted {
            ($0.metric.rawValue, $0.reason?.rawValue ?? "", $0.source?.rawValue ?? "")
                < ($1.metric.rawValue, $1.reason?.rawValue ?? "", $1.source?.rawValue ?? "")
        }

        let fingerprints: Set<AppleModelFingerprint> = Set(
            appleShadowRecords.compactMap { $0.modelFingerprint }
        )
        let unassignedRecords = appleShadowRecords.filter { $0.modelFingerprint == nil }
        let sortedFingerprints = fingerprints.sorted { lhs, rhs in
            lhs.stableIdentifier < rhs.stableIdentifier
        }
        var appleReports: [DeveloperAppleQualificationSummary] = []
        for fingerprint in sortedFingerprints {
            let records = appleShadowRecords.filter { $0.modelFingerprint == fingerprint }
            if let report = try? AppleQualificationEvaluator.report(for: records) {
                appleReports.append(DeveloperAppleQualificationSummary(report))
            }
        }

        let estimates = usageRecords.compactMap(OpenAICostEstimator.estimate)
        let detailedEstimatedCost = estimates.reduce(0) { $0 + $1.amountUSD }
        let retryRecords = retryUsageRecords(in: usageRecords)
        let retryEstimatedCost = retryRecords.compactMap(OpenAICostEstimator.estimate).reduce(0) {
            $0 + $1.amountUSD
        }

        return DeveloperOptimizationReport(
            schemaVersion: DeveloperOptimizationReport.currentSchemaVersion,
            generatedAt: generatedAt,
            detailWindowStart: detailWindowStart,
            aggregateWindowStart: aggregateWindowStart,
            pricing: .current,
            openAI: DeveloperOpenAIReport(
                detailRequestCount: usageRecords.count,
                pricedDetailRequestCount: estimates.count,
                unpricedDetailRequestCount: usageRecords.count - estimates.count,
                pricingCoverageRate: usageRecords.isEmpty
                    ? 1
                    : Double(estimates.count) / Double(usageRecords.count),
                durationEstimatedRequestCount: estimates.filter {
                    $0.basis == .estimatedAudioDuration
                }.count,
                detailEstimatedCostUSD: detailedEstimatedCost,
                retryRequestCount: retryRecords.count,
                retryEstimatedCostUSD: retryEstimatedCost,
                retryCostShare: detailedEstimatedCost > 0
                    ? retryEstimatedCost / detailedEstimatedCost
                    : 0,
                buckets: openAIBuckets,
                dailyAggregates: usageDailyAggregates.map {
                    DeveloperOpenAIDailyUsage(
                        day: $0.day,
                        priceVersion: $0.priceVersion,
                        isExactCost: false,
                        requestCount: $0.requestCount,
                        inputTokens: $0.inputTokens,
                        cachedInputTokens: $0.cachedInputTokens,
                        cacheWriteTokens: $0.cacheWriteTokens,
                        outputTokens: $0.outputTokens,
                        reasoningTokens: $0.reasoningTokens,
                        totalTokens: $0.totalTokens,
                        estimatedCostUSD: $0.estimatedCostUSD
                    )
                }
            ),
            optimization: DeveloperOptimizationTelemetryReport(
                detailRecordCount: optimizationRecords.count,
                buckets: optimizationBuckets,
                dailyAggregates: optimizationDailyAggregates
            ),
            appleShadow: appleReports,
            unassignedAppleShadowRecordCount: unassignedRecords.count
        )
    }

    private static func retryUsageRecords(in records: [OpenAIUsageRecord]) -> [OpenAIUsageRecord] {
        var retryIDs = Set(records.filter { ($0.attemptNumber ?? 1) > 1 }.map(\.id))
        let grouped = Dictionary(grouping: records.compactMap { record in
            record.logicalRequestID.map { ($0, record) }
        }, by: { $0.0 })
        for entries in grouped.values {
            let ordered = entries.map { $0.1 }.sorted {
                if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            retryIDs.formUnion(ordered.dropFirst().map(\.id))
        }
        return records.filter { retryIDs.contains($0.id) }
    }

    private static func openAIBucketKey(_ record: OpenAIUsageRecord) -> OpenAIBucketKey {
        OpenAIBucketKey(
            task: record.task,
            requestedModel: record.requestedModel,
            actualModel: record.actualModel,
            requestedServiceTier: record.requestedServiceTier,
            actualServiceTier: record.actualServiceTier,
            reasoningEffort: record.reasoningEffort,
            maxOutputTokens: record.maxOutputTokens
        )
    }

    private static func makeOpenAIBucket(
        key: OpenAIBucketKey,
        records: [OpenAIUsageRecord]
    ) -> DeveloperOpenAIUsageBucket {
        let inputTokens = records.compactMap { $0.inputTokens }.reduce(0, +)
        let cachedInputTokens = records.compactMap { $0.cachedInputTokens }.reduce(0, +)
        let cacheWriteTokens = records.compactMap { $0.cacheWriteTokens }.reduce(0, +)
        let outputTokens = records.compactMap { $0.outputTokens }.reduce(0, +)
        let reasoningTokens = records.compactMap { $0.reasoningTokens }.reduce(0, +)
        let totalTokens = records.compactMap { $0.totalTokens }.reduce(0, +)
        let estimatedCost = records.reduce(0.0) { partialResult, record in
            partialResult + OpenAICostEstimator.estimatedCostUSD(for: record)
        }
        return DeveloperOpenAIUsageBucket(
            task: key.task,
            requestedModel: key.requestedModel,
            actualModel: key.actualModel,
            requestedServiceTier: key.requestedServiceTier,
            actualServiceTier: key.actualServiceTier,
            reasoningEffort: key.reasoningEffort,
            maxOutputTokens: key.maxOutputTokens,
            requestCount: records.count,
            successCount: records.filter { $0.outcome == .success }.count,
            failureCount: records.filter { $0.outcome == .failure }.count,
            cancelledCount: records.filter { $0.outcome == .cancelled }.count,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            cacheWriteTokens: cacheWriteTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens,
            totalTokens: totalTokens,
            estimatedCostUSD: estimatedCost
        )
    }

    private static func optimizationBucketKey(
        _ record: OptimizationTelemetryRecord
    ) -> OptimizationBucketKey {
        OptimizationBucketKey(
            metric: record.metric,
            reason: record.reason,
            source: record.source,
            isMeeting: record.isMeeting
        )
    }

    private static func makeOptimizationBucket(
        key: OptimizationBucketKey,
        records: [OptimizationTelemetryRecord]
    ) -> DeveloperOptimizationTelemetryBucket {
        let latencies = records.compactMap { $0.latencyMilliseconds }
        let sortedLatencies = latencies.sorted()
        let occurrenceCount = records.reduce(0) { $0 + $1.occurrenceCount }
        let averageLatency = latencies.isEmpty ? nil : latencies.reduce(0, +) / latencies.count
        return DeveloperOptimizationTelemetryBucket(
            metric: key.metric,
            reason: key.reason,
            source: key.source,
            isMeeting: key.isMeeting,
            recordCount: records.count,
            occurrenceCount: occurrenceCount,
            averageLatencyMilliseconds: averageLatency,
            p95LatencyMilliseconds: sortedLatencies.isEmpty
                ? nil
                : sortedLatencies[max(0, Int(ceil(Double(sortedLatencies.count) * 0.95)) - 1)],
            maximumQueueDepth: records.compactMap { $0.queueDepth }.max()
        )
    }
}

enum DeveloperOptimizationReportFormat: Sendable {
    case json
    case markdown
}

enum DeveloperOptimizationReportExporter {
    static func data(
        for report: DeveloperOptimizationReport,
        format: DeveloperOptimizationReportFormat
    ) throws -> Data {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(report)
        case .markdown:
            return Data(markdown(for: report).utf8)
        }
    }

    static func write(
        _ report: DeveloperOptimizationReport,
        format: DeveloperOptimizationReportFormat,
        to url: URL
    ) throws {
        try data(for: report, format: format).write(to: url, options: .atomic)
    }

    static func markdown(for report: DeveloperOptimizationReport) -> String {
        var lines = [
            "# Iriz optimization report",
            "",
            "- Schema: `\(report.schemaVersion)`",
            "- Price version: `\(report.pricing.priceVersion)`",
            "- Cost: estimated USD, not an invoice or exact billed amount",
            "- Detailed requests: \(report.openAI.detailRequestCount)",
            "- Pricing coverage: \(percent(report.openAI.pricingCoverageRate)) (\(report.openAI.unpricedDetailRequestCount) unpriced)",
            "- Duration-estimated transcription requests: \(report.openAI.durationEstimatedRequestCount)",
            "- Detailed estimated cost: \(usd(report.openAI.detailEstimatedCostUSD))",
            "- Retry requests: \(report.openAI.retryRequestCount)",
            "- Retry estimated cost: \(usd(report.openAI.retryEstimatedCostUSD)) (\(percent(report.openAI.retryCostShare)) of detailed estimate)",
            "",
            "## OpenAI usage",
            "",
            "| Task | Requested model | Tier | Requests | Input | Cached | Cache writes | Output | Estimated USD |",
            "|---|---|---:|---:|---:|---:|---:|---:|---:|"
        ]
        for bucket in report.openAI.buckets {
            lines.append(
                "| \(cell(bucket.task)) | \(cell(bucket.requestedModel)) | \(cell(bucket.requestedServiceTier)) | "
                    + "\(bucket.requestCount) | \(bucket.inputTokens) | \(bucket.cachedInputTokens) | "
                    + "\(bucket.cacheWriteTokens) | \(bucket.outputTokens) | \(usd(bucket.estimatedCostUSD)) |"
            )
        }
        lines.append(contentsOf: [
            "",
            "### Daily aggregates",
            "",
            "| Day | Price version | Requests | Input | Cached | Cache writes | Output | Estimated USD |",
            "|---|---|---:|---:|---:|---:|---:|---:|"
        ])
        for daily in report.openAI.dailyAggregates {
            lines.append(
                "| \(cell(daily.day)) | \(cell(daily.priceVersion)) | \(daily.requestCount) | "
                    + "\(daily.inputTokens) | \(daily.cachedInputTokens) | \(daily.cacheWriteTokens) | "
                    + "\(daily.outputTokens) | \(usd(daily.estimatedCostUSD)) |"
            )
        }
        lines.append(contentsOf: [
            "",
            "## Optimization telemetry",
            "",
            "| Metric | Reason | Source | Records | Occurrences | Avg latency ms | p95 latency ms | Max queue |",
            "|---|---|---|---:|---:|---:|---:|---:|"
        ])
        for bucket in report.optimization.buckets {
            lines.append(
                "| \(cell(bucket.metric.rawValue)) | \(cell(bucket.reason?.rawValue ?? "-")) | "
                    + "\(cell(bucket.source?.rawValue ?? "-")) | \(bucket.recordCount) | \(bucket.occurrenceCount) | "
                    + "\(bucket.averageLatencyMilliseconds.map(String.init) ?? "-") | "
                    + "\(bucket.p95LatencyMilliseconds.map(String.init) ?? "-") | "
                    + "\(bucket.maximumQueueDepth.map(String.init) ?? "-") |"
            )
        }
        lines.append(contentsOf: ["", "## Apple Shadow qualification", ""])
        if report.appleShadow.isEmpty {
            lines.append("No single-fingerprint qualification report is available.")
        } else {
            lines.append("| Fingerprint | Observations | Gate decisions | False rejects | Critical bypass violations | Critical false rejects | Valid gate output | Gate p95 ms | Gate qualified | Local drafts | Valid drafts | Cloud compatible | Critical mismatches | Safety violations | Draft p95 ms | Drafts qualified |")
            lines.append("|---|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---|")
            for value in report.appleShadow {
                lines.append(
                    "| \(cell(value.fingerprint.stableIdentifier)) | \(value.observationCount) | "
                        + "\(value.gateDecisionCount) | \(value.falseRejectionCount) | "
                        + "\(value.criticalBypassViolationCount) | \(value.criticalFalseRejectionCount) | "
                        + "\(percent(value.structuredValidityRate)) | "
                        + "\(value.warmUncachedLatencyP95Milliseconds.map(String.init) ?? "-") | "
                        + "\(value.qualifiesGate ? "yes" : "no") | \(value.localEventAttemptCount) | "
                        + "\(percent(value.localEventValidityRate)) | "
                        + "\(percent(value.localEventCloudCompatibilityRate)) | "
                        + "\(value.localEventCriticalMismatchCount) | \(value.localEventSafetyViolationCount) | "
                        + "\(value.localEventLatencyP95Milliseconds.map(String.init) ?? "-") | "
                        + "\(value.qualifiesLocalEvents ? "yes" : "no") |"
                )
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func cell(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

    private static func usd(_ value: Double) -> String {
        String(format: "$%.6f", value)
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.3f%%", value * 100)
    }
}

enum DeveloperOptimizationReportService {
    static func makeReport(
        repository: any LogRepository,
        now: Date = Date()
    ) async throws -> DeveloperOptimizationReport {
        let detailStart = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let aggregateStart = now.addingTimeInterval(-90 * 24 * 60 * 60)
        async let usageRecords = repository.openAIUsageRecords(since: detailStart, limit: 100_000)
        async let usageDaily = repository.openAIUsageDailyAggregates(since: aggregateStart)
        async let optimizationRecords = repository.optimizationTelemetryRecords(since: detailStart, limit: 100_000)
        async let optimizationDaily = repository.optimizationTelemetryDailyAggregates(since: aggregateStart)
        async let appleRecords = repository.appleShadowQualificationRecords(since: detailStart, limit: 100_000)
        return try await DeveloperOptimizationReportBuilder.build(
            generatedAt: now,
            detailWindowStart: detailStart,
            aggregateWindowStart: aggregateStart,
            usageRecords: usageRecords,
            usageDailyAggregates: usageDaily,
            optimizationRecords: optimizationRecords,
            optimizationDailyAggregates: optimizationDaily,
            appleShadowRecords: appleRecords
        )
    }
}
