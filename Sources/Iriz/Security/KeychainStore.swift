import Foundation
import LocalAuthentication
import Security

enum KeychainStoreError: LocalizedError {
    case unhandled(OSStatus)
    case invalidData

    var requiresUserApproval: Bool {
        switch self {
        case .unhandled(let status):
            status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecUserCanceled
        case .invalidData:
            false
        }
    }

    var errorDescription: String? {
        switch self {
        case .unhandled(let status):
            SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        case .invalidData:
            "The Keychain item contained invalid data."
        }
    }
}

enum KeychainInteraction: Equatable, Sendable {
    /// Background checks must never display a macOS password or authorization dialog.
    case nonInteractive
    /// Reserved for an action the user explicitly initiated in the Iriz interface.
    case userInitiated
}

struct KeychainStore: Sendable {
    static let shared = KeychainStore(service: "com.iriz.memory")

    let service: String

    func readData(account: String, interaction: KeychainInteraction = .nonInteractive) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        applyInteraction(interaction, to: &query)

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStoreError.unhandled(status) }
        guard let data = result as? Data else { throw KeychainStoreError.invalidData }
        return data
    }

    func writeData(
        _ data: Data,
        account: String,
        interaction: KeychainInteraction = .nonInteractive
    ) throws {
        var lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        applyInteraction(interaction, to: &lookup)
        let updates: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(lookup as CFDictionary, updates as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainStoreError.unhandled(updateStatus)
        }

        var insertion = lookup
        insertion[kSecValueData as String] = data
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainStoreError.unhandled(addStatus) }
    }

    func delete(account: String, interaction: KeychainInteraction = .userInitiated) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        applyInteraction(interaction, to: &query)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unhandled(status)
        }
    }

    func readString(
        account: String,
        interaction: KeychainInteraction = .nonInteractive
    ) throws -> String? {
        guard let data = try readData(account: account, interaction: interaction) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.invalidData
        }
        return value
    }

    func writeString(
        _ value: String,
        account: String,
        interaction: KeychainInteraction = .userInitiated
    ) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainStoreError.invalidData }
        try writeData(data, account: account, interaction: interaction)
    }

    private func applyInteraction(_ interaction: KeychainInteraction, to query: inout [String: Any]) {
        if interaction == .nonInteractive {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
    }
}

enum KeychainAccounts {
    static let openAIAPIKey = "openai-api-key"
    static let databaseKey = "database-key-v1"
    static let mediaKey = "media-key-v1"
    static let voiceReference = "voice-reference-v1"
}
