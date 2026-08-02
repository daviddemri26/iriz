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

enum DistributionEnvironment {
    private static let stableKeychainMarker = "iriz.keychain.stable-signature-ready"

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
        if isAdHocBuild { return true }
        // The first stable build must migrate an existing development journal deliberately.
        // This prevents a legacy ad hoc ACL from surprising the user.
        return hasExistingJournal && !UserDefaults.standard.bool(forKey: stableKeychainMarker)
    }

    static func markStableKeychainReady() {
        guard !isAdHocBuild else { return }
        UserDefaults.standard.set(true, forKey: stableKeychainMarker)
    }

    private static var hasExistingJournal: Bool {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return false }
        return FileManager.default.fileExists(
            atPath: support
                .appendingPathComponent("Iriz", isDirectory: true)
                .appendingPathComponent("Iriz.sqlite.iriz")
                .path
        )
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
