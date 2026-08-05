import Foundation

/// Public Speech does not expose an asset model build identifier. Key approval
/// to the complete OS build plus the Speech framework and harness versions so
/// an OS/model update cannot silently inherit a previous qualification.
struct SpeechAnalyzerModelFingerprint: Codable, Equatable, Hashable, Sendable {
    var operatingSystemVersion: String
    var speechFrameworkVersion: String
    var architecture: String
    var harnessVersion: Int

    static func current(harnessVersion: Int = 1) -> SpeechAnalyzerModelFingerprint {
        let speechBundle = Bundle(identifier: "com.apple.Speech")
            ?? Bundle(path: "/System/Library/Frameworks/Speech.framework")
        let shortVersion = speechBundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildVersion = speechBundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let frameworkVersion = [shortVersion, buildVersion]
            .compactMap { $0 }
            .joined(separator: " (")
            .appending(buildVersion == nil || shortVersion == nil ? "" : ")")

        return SpeechAnalyzerModelFingerprint(
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            speechFrameworkVersion: frameworkVersion.isEmpty ? "unknown" : frameworkVersion,
            architecture: Self.currentArchitecture,
            harnessVersion: harnessVersion
        )
    }

    private static var currentArchitecture: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
        "unknown"
#endif
    }
}

enum SpeechAnalyzerActionSignal: String, Codable, CaseIterable, Hashable, Sendable {
    case commitment
    case deadline
    case completion
    case decision
    case transaction
    case appointment
    case explicitNextStep
}

/// One manually-labelled comparison between a reference transcript and the
/// local SpeechAnalyzer result. `criticalError` covers polarity, actor, amount,
/// date, or completion changes that a simple keyword recall cannot detect.
struct SpeechAnalyzerQualificationRecord: Codable, Equatable, Sendable {
    var id: UUID
    var languageCode: String
    var fingerprint: SpeechAnalyzerModelFingerprint
    var referenceSignals: Set<SpeechAnalyzerActionSignal>
    var recognizedSignals: Set<SpeechAnalyzerActionSignal>
    var transcriptionSucceeded: Bool
    var criticalError: Bool

    init(
        id: UUID = UUID(),
        languageCode: String,
        fingerprint: SpeechAnalyzerModelFingerprint,
        referenceSignals: Set<SpeechAnalyzerActionSignal>,
        recognizedSignals: Set<SpeechAnalyzerActionSignal>,
        transcriptionSucceeded: Bool = true,
        criticalError: Bool = false
    ) {
        self.id = id
        self.languageCode = Self.normalizedLanguageCode(languageCode)
        self.fingerprint = fingerprint
        self.referenceSignals = referenceSignals
        self.recognizedSignals = recognizedSignals
        self.transcriptionSucceeded = transcriptionSucceeded
        self.criticalError = criticalError
    }

    static func normalizedLanguageCode(_ value: String) -> String {
        value
            .lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init) ?? ""
    }
}

struct SpeechAnalyzerQualificationThresholds: Equatable, Sendable {
    var minimumSegmentCount = 200
    var requiredLanguageCodes: Set<String> = ["en", "fr"]
    var minimumSegmentsPerLanguage = 50
    var minimumReferenceActionSignals = 100
    var minimumActionSignalRecall = 0.99
    var maximumCriticalErrors = 0
}

struct SpeechAnalyzerQualificationReport: Equatable, Sendable {
    var segmentCount: Int
    var successfulSegmentCount: Int
    var segmentCountByLanguage: [String: Int]
    var fingerprint: SpeechAnalyzerModelFingerprint?
    var mixedFingerprints: Bool
    var referenceActionSignalCount: Int
    var recalledActionSignalCount: Int
    var criticalErrorCount: Int
    var thresholds: SpeechAnalyzerQualificationThresholds

    var actionSignalRecall: Double {
        guard referenceActionSignalCount > 0 else { return 0 }
        return Double(recalledActionSignalCount) / Double(referenceActionSignalCount)
    }

    var qualifies: Bool {
        segmentCount >= thresholds.minimumSegmentCount
            && !mixedFingerprints
            && fingerprint != nil
            && thresholds.requiredLanguageCodes.allSatisfy {
                segmentCountByLanguage[$0, default: 0] >= thresholds.minimumSegmentsPerLanguage
            }
            && referenceActionSignalCount >= thresholds.minimumReferenceActionSignals
            && actionSignalRecall >= thresholds.minimumActionSignalRecall
            && criticalErrorCount <= thresholds.maximumCriticalErrors
    }
}

enum SpeechAnalyzerQualificationEvaluator {
    static func report(
        for records: [SpeechAnalyzerQualificationRecord],
        thresholds: SpeechAnalyzerQualificationThresholds = SpeechAnalyzerQualificationThresholds()
    ) -> SpeechAnalyzerQualificationReport {
        let fingerprints = Set(records.map(\.fingerprint))
        var languageCounts: [String: Int] = [:]
        var referenceSignalCount = 0
        var recalledSignalCount = 0

        for record in records {
            languageCounts[record.languageCode, default: 0] += 1
            referenceSignalCount += record.referenceSignals.count
            recalledSignalCount += record.referenceSignals.intersection(record.recognizedSignals).count
        }

        return SpeechAnalyzerQualificationReport(
            segmentCount: records.count,
            successfulSegmentCount: records.filter(\.transcriptionSucceeded).count,
            segmentCountByLanguage: languageCounts,
            fingerprint: fingerprints.count == 1 ? fingerprints.first : nil,
            mixedFingerprints: fingerprints.count > 1,
            referenceActionSignalCount: referenceSignalCount,
            recalledActionSignalCount: recalledSignalCount,
            criticalErrorCount: records.filter { $0.criticalError || !$0.transcriptionSucceeded }.count,
            thresholds: thresholds
        )
    }
}

/// Profiles are code-reviewed release inputs. The evaluator deliberately never
/// writes this registry, and no client corpus can promote its own model.
struct SpeechAnalyzerQualificationProfile: Codable, Equatable, Sendable {
    var fingerprint: SpeechAnalyzerModelFingerprint
    var approvedLanguageCodes: Set<String>
    var corpusDigest: String
    var approvedAt: Date
    var segmentCount: Int
    var actionSignalRecall: Double
    var criticalErrorCount: Int

    var isQualificationEvidenceValid: Bool {
        approvedLanguageCodes.isSuperset(of: ["en", "fr"])
            && !corpusDigest.isEmpty
            && segmentCount >= 200
            && actionSignalRecall >= 0.99
            && criticalErrorCount == 0
    }

    func accepts(fingerprint candidate: SpeechAnalyzerModelFingerprint, languageCode: String) -> Bool {
        isQualificationEvidenceValid
            && fingerprint == candidate
            && approvedLanguageCodes.contains(SpeechAnalyzerQualificationRecord.normalizedLanguageCode(languageCode))
    }
}

enum SpeechAnalyzerQualificationRegistry {
    /// Intentionally empty until a developer-approved FR/EN corpus qualifies an
    /// exact fingerprint and the resulting profile ships in an app update.
    static let embeddedApprovedProfiles: [SpeechAnalyzerQualificationProfile] = []

    static func approvedProfile(
        for fingerprint: SpeechAnalyzerModelFingerprint,
        languageCode: String
    ) -> SpeechAnalyzerQualificationProfile? {
        embeddedApprovedProfiles.first { $0.accepts(fingerprint: fingerprint, languageCode: languageCode) }
    }
}
