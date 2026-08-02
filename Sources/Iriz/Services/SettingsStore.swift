import Combine
import Foundation
import ServiceManagement

enum APIKeyState: Equatable {
    case missing
    case saved
    case testing
    case valid
    case invalid(String)

    var displayName: String {
        switch self {
        case .missing: "No API key saved"
        case .saved: "API key saved in Keychain"
        case .testing: "Testing connection…"
        case .valid: "Connected to OpenAI"
        case .invalid(let message): message
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

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = .shared) {
        self.defaults = defaults
        self.keychain = keychain
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(IrizSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = IrizSettings()
        }
        self.apiKeyState = ((try? keychain.readString(account: KeychainAccounts.openAIAPIKey)) ?? nil) == nil ? .missing : .saved
        self.languages = LanguageOption.allOptions()
    }

    func apiKey() throws -> String? {
        try keychain.readString(account: KeychainAccounts.openAIAPIKey)
    }

    func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try removeAPIKey()
            return
        }
        try keychain.writeString(trimmed, account: KeychainAccounts.openAIAPIKey)
        apiKeyState = .saved
    }

    func removeAPIKey() throws {
        try keychain.delete(account: KeychainAccounts.openAIAPIKey)
        apiKeyState = .missing
    }

    func voiceReference() throws -> Data? {
        try keychain.readData(account: KeychainAccounts.voiceReference)
    }

    func saveVoiceReference(_ data: Data) throws {
        try keychain.writeData(data, account: KeychainAccounts.voiceReference)
        settings.voiceEnrollmentEnabled = true
    }

    func removeVoiceReference() throws {
        try keychain.delete(account: KeychainAccounts.voiceReference)
        settings.voiceEnrollmentEnabled = false
    }

    func setAPIKeyState(_ state: APIKeyState) {
        apiKeyState = state
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
