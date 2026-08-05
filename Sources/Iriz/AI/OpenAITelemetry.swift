import Foundation

enum OpenAIServiceTier: String, Codable, CaseIterable, Sendable {
    case `default`
    case flex
}

enum OpenAITextVerbosity: String, Codable, CaseIterable, Sendable {
    case low
    case medium
}

enum OpenAIRequestOutcome: String, Codable, Sendable {
    case success
    case failure
    case cancelled
}

struct OpenAIResponseUsage: Codable, Equatable, Sendable {
    let inputTokens: Int?
    let cachedInputTokens: Int?
    let cacheWriteTokens: Int?
    let outputTokens: Int?
    let reasoningTokens: Int?
    let totalTokens: Int?

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case inputTokensDetails = "input_tokens_details"
        case outputTokens = "output_tokens"
        case outputTokensDetails = "output_tokens_details"
        case totalTokens = "total_tokens"
    }

    private struct InputDetails: Codable, Equatable, Sendable {
        let cachedTokens: Int?
        let cacheWriteTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case cachedTokens = "cached_tokens"
            case cacheWriteTokens = "cache_write_tokens"
        }
    }

    private struct OutputDetails: Codable, Equatable, Sendable {
        let reasoningTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case reasoningTokens = "reasoning_tokens"
        }
    }

    init(
        inputTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        outputTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        totalTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.totalTokens = totalTokens
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let inputDetails = try container.decodeIfPresent(InputDetails.self, forKey: .inputTokensDetails)
        let outputDetails = try container.decodeIfPresent(OutputDetails.self, forKey: .outputTokensDetails)
        inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens)
        cachedInputTokens = inputDetails?.cachedTokens
        cacheWriteTokens = inputDetails?.cacheWriteTokens
        outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens)
        reasoningTokens = outputDetails?.reasoningTokens
        totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(inputTokens, forKey: .inputTokens)
        if cachedInputTokens != nil || cacheWriteTokens != nil {
            try container.encode(
                InputDetails(cachedTokens: cachedInputTokens, cacheWriteTokens: cacheWriteTokens),
                forKey: .inputTokensDetails
            )
        }
        try container.encodeIfPresent(outputTokens, forKey: .outputTokens)
        if reasoningTokens != nil {
            try container.encode(OutputDetails(reasoningTokens: reasoningTokens), forKey: .outputTokensDetails)
        }
        try container.encodeIfPresent(totalTokens, forKey: .totalTokens)
    }
}

struct OpenAIResponseMetadata: Codable, Equatable, Sendable {
    struct IncompleteDetails: Codable, Equatable, Sendable {
        let reason: String?
    }

    let id: String?
    let model: String?
    let status: String?
    let serviceTier: String?
    let incompleteDetails: IncompleteDetails?
    let usage: OpenAIResponseUsage?

    private enum CodingKeys: String, CodingKey {
        case id
        case model
        case status
        case serviceTier = "service_tier"
        case incompleteDetails = "incomplete_details"
        case usage
    }

    static func decodeIfPresent(from data: Data) -> OpenAIResponseMetadata? {
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(OpenAIResponseMetadata.self, from: data)
    }
}

struct OpenAIResponseHeaders: Codable, Equatable, Sendable {
    let requestID: String?
    let processingMilliseconds: Double?
    let retryAfter: String?
    let rateLimits: [String: String]

    init(response: HTTPURLResponse) {
        requestID = response.value(forHTTPHeaderField: "x-request-id")
        processingMilliseconds = response.value(forHTTPHeaderField: "openai-processing-ms").flatMap(Double.init)
        retryAfter = response.value(forHTTPHeaderField: "retry-after")

        var limits: [String: String] = [:]
        for (rawName, rawValue) in response.allHeaderFields {
            let name = String(describing: rawName).lowercased()
            guard name.hasPrefix("x-ratelimit-") else { continue }
            limits[name] = String(describing: rawValue)
        }
        rateLimits = limits
    }
}

struct OpenAIUsageRecord: Codable, Equatable, Sendable {
    let id: UUID
    let attemptID: UUID
    let startedAt: Date
    let durationSeconds: TimeInterval
    let task: String
    let requestedModel: String
    let responseID: String?
    let actualModel: String?
    let requestedServiceTier: String
    let actualServiceTier: String?
    let reasoningEffort: String?
    let maxOutputTokens: Int?
    let outcome: OpenAIRequestOutcome
    let httpStatus: Int?
    let responseStatus: String?
    let incompleteReason: String?
    let inputTokens: Int?
    let cachedInputTokens: Int?
    let cacheWriteTokens: Int?
    let outputTokens: Int?
    let reasoningTokens: Int?
    let totalTokens: Int?
    let requestBytes: Int
    let responseBytes: Int
    let imageCount: Int
    let audioDurationSeconds: TimeInterval?
    let requestID: String?
    let processingMilliseconds: Double?
    let retryAfter: String?
    let rateLimits: [String: String]
    let errorKind: String?

    init(
        id: UUID = UUID(),
        attemptID: UUID,
        startedAt: Date,
        durationSeconds: TimeInterval,
        task: String,
        requestedModel: String,
        responseID: String?,
        actualModel: String?,
        requestedServiceTier: String,
        actualServiceTier: String?,
        reasoningEffort: String?,
        maxOutputTokens: Int?,
        outcome: OpenAIRequestOutcome,
        httpStatus: Int?,
        responseStatus: String?,
        incompleteReason: String?,
        usage: OpenAIResponseUsage?,
        requestBytes: Int,
        responseBytes: Int,
        imageCount: Int,
        audioDurationSeconds: TimeInterval?,
        headers: OpenAIResponseHeaders?,
        errorKind: String?
    ) {
        self.id = id
        self.attemptID = attemptID
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.task = task
        self.requestedModel = requestedModel
        self.responseID = responseID
        self.actualModel = actualModel
        self.requestedServiceTier = requestedServiceTier
        self.actualServiceTier = actualServiceTier
        self.reasoningEffort = reasoningEffort
        self.maxOutputTokens = maxOutputTokens
        self.outcome = outcome
        self.httpStatus = httpStatus
        self.responseStatus = responseStatus
        self.incompleteReason = incompleteReason
        inputTokens = usage?.inputTokens
        cachedInputTokens = usage?.cachedInputTokens
        cacheWriteTokens = usage?.cacheWriteTokens
        outputTokens = usage?.outputTokens
        reasoningTokens = usage?.reasoningTokens
        totalTokens = usage?.totalTokens
        self.requestBytes = requestBytes
        self.responseBytes = responseBytes
        self.imageCount = imageCount
        self.audioDurationSeconds = audioDurationSeconds
        requestID = headers?.requestID
        processingMilliseconds = headers?.processingMilliseconds
        retryAfter = headers?.retryAfter
        rateLimits = headers?.rateLimits ?? [:]
        self.errorKind = errorKind
    }
}

protocol OpenAIUsageRecording: Sendable {
    func record(_ record: OpenAIUsageRecord) async
}

struct NoOpOpenAIUsageRecorder: OpenAIUsageRecording {
    func record(_ record: OpenAIUsageRecord) async {}
}

actor InMemoryOpenAIUsageRecorder: OpenAIUsageRecording {
    private var values: [OpenAIUsageRecord] = []

    func record(_ record: OpenAIUsageRecord) {
        values.append(record)
    }

    func records() -> [OpenAIUsageRecord] {
        values
    }
}

struct OpenAIRequestTelemetryContext: Equatable, Sendable {
    let attemptID: UUID
    let task: String
    let requestedModel: String
    let requestedServiceTier: String
    let reasoningEffort: String?
    let maxOutputTokens: Int?
    let requestBytes: Int
    let imageCount: Int
    let audioDurationSeconds: TimeInterval?

    static func response(task: String, body: Data) -> OpenAIRequestTelemetryContext {
        let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let reasoning = root?["reasoning"] as? [String: Any]
        return OpenAIRequestTelemetryContext(
            attemptID: UUID(),
            task: task,
            requestedModel: root?["model"] as? String ?? "unknown",
            requestedServiceTier: root?["service_tier"] as? String ?? OpenAIServiceTier.default.rawValue,
            reasoningEffort: reasoning?["effort"] as? String,
            maxOutputTokens: root?["max_output_tokens"] as? Int,
            requestBytes: body.count,
            imageCount: countInputImages(in: root),
            audioDurationSeconds: nil
        )
    }

    static func transcription(task: String, model: String, body: Data, wavData: Data) -> OpenAIRequestTelemetryContext {
        OpenAIRequestTelemetryContext(
            attemptID: UUID(),
            task: task,
            requestedModel: model,
            requestedServiceTier: OpenAIServiceTier.default.rawValue,
            reasoningEffort: nil,
            maxOutputTokens: nil,
            requestBytes: body.count,
            imageCount: 0,
            audioDurationSeconds: wavDuration(from: wavData)
        )
    }

    private static func countInputImages(in value: Any?) -> Int {
        if let dictionary = value as? [String: Any] {
            let ownCount = dictionary["type"] as? String == "input_image" ? 1 : 0
            return ownCount + dictionary.values.reduce(0) { $0 + countInputImages(in: $1) }
        }
        if let array = value as? [Any] {
            return array.reduce(0) { $0 + countInputImages(in: $1) }
        }
        return 0
    }

    private static func wavDuration(from data: Data) -> TimeInterval? {
        guard data.count >= 44,
              String(decoding: data[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: data[8..<12], as: UTF8.self) == "WAVE" else {
            return nil
        }
        let byteRate = data.readLittleEndianUInt32(at: 28)
        guard byteRate > 0 else { return nil }
        let payloadBytes = max(0, data.count - 44)
        return Double(payloadBytes) / Double(byteRate)
    }
}

private extension Data {
    func readLittleEndianUInt32(at offset: Int) -> UInt32 {
        guard offset >= 0, count >= offset + 4 else { return 0 }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
