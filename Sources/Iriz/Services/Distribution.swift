import Foundation

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
