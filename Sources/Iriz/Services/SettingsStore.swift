import Combine
import Foundation
import ServiceManagement

enum APIKeyState: Equatable, Sendable {
    case checking
    case needsApproval
    case missing
    case saved
    case testing
    case valid
    case invalid(String)

    var displayName: String {
        switch self {
        case .checking: "Checking Keychain…"
        case .needsApproval: "Keychain approval required"
        case .missing: "No API key saved"
        case .saved: "API key saved in Keychain"
        case .testing: "Testing connection…"
        case .valid: "Connected to OpenAI"
        case .invalid(let message): message
        }
    }

    var canRemove: Bool {
        switch self {
        case .saved, .valid: true
        case .checking, .needsApproval, .missing, .testing, .invalid: false
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var settings: IrizSettings {
        didSet { persist() }
    }
    @Published private(set) var apiKeyState: APIKeyState

    let languages: [LanguageOption]
    private let defaults: UserDefaults
    private let keychain: KeychainStore
    private let storageKey = "iriz.settings.v1"
    private var cachedAPIKey: String?
    private var cachedVoiceReference: Data?

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = .shared) {
        self.defaults = defaults
        self.keychain = keychain
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(IrizSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = IrizSettings()
        }
        self.apiKeyState = .checking
        self.languages = LanguageOption.allOptions()
    }

    func apiKey() throws -> String? {
        cachedAPIKey
    }

    func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try removeAPIKey()
            return
        }
        try keychain.writeString(
            trimmed,
            account: KeychainAccounts.openAIAPIKey,
            interaction: .userInitiated
        )
        cachedAPIKey = trimmed
        apiKeyState = .saved
    }

    func removeAPIKey() throws {
        try keychain.delete(account: KeychainAccounts.openAIAPIKey, interaction: .userInitiated)
        cachedAPIKey = nil
        apiKeyState = .missing
    }

    func voiceReference() throws -> Data? {
        cachedVoiceReference
    }

    func saveVoiceReference(_ data: Data) throws {
        try keychain.writeData(data, account: KeychainAccounts.voiceReference, interaction: .userInitiated)
        cachedVoiceReference = data
        settings.voiceEnrollmentEnabled = true
    }

    func removeVoiceReference() throws {
        try keychain.delete(account: KeychainAccounts.voiceReference, interaction: .userInitiated)
        cachedVoiceReference = nil
        settings.voiceEnrollmentEnabled = false
    }

    func setAPIKeyState(_ state: APIKeyState) {
        apiKeyState = state
    }

    func installKeychainCache(apiKey: String?, voiceReference: Data?) {
        cachedAPIKey = apiKey
        cachedVoiceReference = voiceReference
        if apiKeyState == .checking || apiKeyState == .needsApproval {
            apiKeyState = apiKey == nil ? .missing : .saved
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        settings.launchAtLogin = enabled
    }

    func outputLanguageDescription() -> String {
        guard settings.outputLanguageTag != "auto" else { return "the source language" }
        return languages.first(where: { $0.identifier == settings.outputLanguageTag })?.displayName
            ?? settings.outputLanguageTag
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
