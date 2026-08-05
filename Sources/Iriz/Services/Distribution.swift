import Foundation

enum IrizBuildChannel: String, Equatable, Sendable {
    case development = "Development"
    case releaseCandidate = "ReleaseCandidate"
    case standalone = "Standalone"
    case setapp = "Setapp"

    var displayName: String {
        switch self {
        case .development: "Development"
        case .releaseCandidate: "Local Release Candidate"
        case .standalone: "Standalone"
        case .setapp: "Setapp"
        }
    }

    static func resolve(infoDictionary: [String: Any]?, isDebug: Bool) -> IrizBuildChannel {
        if isDebug { return .development }
        guard let value = infoDictionary?["IrizBuildChannel"] as? String,
              let channel = IrizBuildChannel(rawValue: value) else {
            return .development
        }
        return channel
    }
}

enum IrizOptimizationStage: String, CaseIterable, Equatable, Sendable {
    case baseline
    case process
    case appleShadow = "apple-shadow"
    case adaptive
    case terra
    case localEvents = "local-events"
    case speech
    case production

    static func resolve(
        infoDictionary: [String: Any]?,
        buildChannel: IrizBuildChannel
    ) -> IrizOptimizationStage {
        if let rawValue = infoDictionary?["IrizOptimizationStage"] as? String,
           let stage = IrizOptimizationStage(rawValue: rawValue.lowercased()) {
            return stage
        }
        return switch buildChannel {
        case .development, .releaseCandidate: .baseline
        case .standalone, .setapp: .production
        }
    }

    var localGateMode: LocalGateMode {
        switch self {
        case .baseline, .process: .disabled
        case .appleShadow: .shadow
        case .adaptive, .terra, .localEvents, .speech, .production: .adaptive
        }
    }

    var localEventDraftPolicy: LocalEventDraftPolicy {
        switch self {
        case .appleShadow: .shadowOnly
        case .localEvents, .speech, .production: .routing
        case .baseline, .process, .adaptive, .terra: .disabled
        }
    }

    var allowsDeferredTerra: Bool {
        switch self {
        case .terra, .localEvents, .speech, .production: true
        case .baseline, .process, .appleShadow, .adaptive: false
        }
    }

    var allowsLocalSpeech: Bool {
        self == .speech || self == .production
    }
}

enum DistributionEnvironment {
    static var buildChannel: IrizBuildChannel {
#if DEBUG
        IrizBuildChannel.resolve(infoDictionary: Bundle.main.infoDictionary, isDebug: true)
#else
        IrizBuildChannel.resolve(infoDictionary: Bundle.main.infoDictionary, isDebug: false)
#endif
    }

    static var isAdHocBuild: Bool {
#if DEBUG
        true
#else
        Bundle.main.object(forInfoDictionaryKey: "IrizAdHocBuild") as? Bool ?? false
#endif
    }

    static var optimizationStage: IrizOptimizationStage {
        IrizOptimizationStage.resolve(
            infoDictionary: Bundle.main.infoDictionary,
            buildChannel: buildChannel
        )
    }

    static var permissionTestingDescription: String {
        switch buildChannel {
        case .development:
            "Development build: macOS can treat each ad hoc rebuild as a different app. Permission results are not release acceptance."
        case .releaseCandidate:
            "Local Release Candidate: this app uses Developer ID and a stable Applications path, so permission and update tests are representative. Public distribution still requires notarization."
        case .standalone:
            "Standalone release: this build is intended for Developer ID signing and Apple notarization."
        case .setapp:
            "Setapp release: signing, notarization and updates are managed by the Setapp distribution adapter."
        }
    }

    static var requiresExplicitKeychainUnlock: Bool {
        isAdHocBuild
    }
}

/// Signed-build feature switches keep rollout stages independently reversible.
/// Apple Shadow can therefore be qualified before deferred/Flex Terra work is
/// enabled, without exposing an optimization preference to users.
enum OptimizationRuntimePolicy {
    static var stage: IrizOptimizationStage { DistributionEnvironment.optimizationStage }

    static var localGateMode: LocalGateMode { stage.localGateMode }

    static var localEventDraftPolicy: LocalEventDraftPolicy { stage.localEventDraftPolicy }

    static var localSpeechEnabled: Bool { stage.allowsLocalSpeech }

    static var deferredTerraRefinementEnabled: Bool {
        resolveDeferredTerraRefinement(
            infoDictionary: Bundle.main.infoDictionary,
            buildChannel: DistributionEnvironment.buildChannel
        )
    }

    static func resolveDeferredTerraRefinement(
        infoDictionary: [String: Any]?,
        buildChannel: IrizBuildChannel
    ) -> Bool {
        let stage = IrizOptimizationStage.resolve(
            infoDictionary: infoDictionary,
            buildChannel: buildChannel
        )
        guard stage.allowsDeferredTerra else { return false }
        if let configured = infoDictionary?["IrizDeferredTerraRefinement"] as? Bool {
            return configured
        }
        if let number = infoDictionary?["IrizDeferredTerraRefinement"] as? NSNumber {
            return number.boolValue
        }
        return switch buildChannel {
        case .development, .releaseCandidate:
            false
        case .standalone, .setapp:
            true
        }
    }
}

protocol DistributionAdapter: Sendable {
    var channelName: String { get }
    var usesExternalLicensing: Bool { get }
    func validateAccess() async -> Bool
}

struct StandaloneDistribution: DistributionAdapter {
    let channelName = "Standalone"
    let usesExternalLicensing = false
    func validateAccess() async -> Bool { true }
}

struct SetappDistribution: DistributionAdapter {
    let channelName = "Setapp"
    let usesExternalLicensing = true

    func validateAccess() async -> Bool {
        // The Setapp SDK implementation is intentionally supplied only in the Setapp build target.
        false
    }
}
