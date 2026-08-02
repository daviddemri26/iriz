import Foundation

enum DistributionEnvironment {
    private static let stableKeychainMarker = "iriz.keychain.stable-signature-ready"

    static var isAdHocBuild: Bool {
#if DEBUG
        true
#else
        Bundle.main.object(forInfoDictionaryKey: "IrizAdHocBuild") as? Bool ?? false
#endif
    }

    static var requiresExplicitKeychainUnlock: Bool {
        if isAdHocBuild { return true }
        // The first Developer ID build must migrate an existing development journal
        // deliberately. This prevents a legacy ad hoc ACL from surprising the user.
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
