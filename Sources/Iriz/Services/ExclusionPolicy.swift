import Foundation

enum ExclusionPolicy {
    static let defaultExcludedBundleIdentifiers: Set<String> = [
        "com.apple.Passwords",
        "com.apple.keychainaccess",
        "com.agilebits.onepassword7",
        "com.1password.1password",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.dashlane.Dashlane"
    ]

    static func shouldExclude(
        bundleIdentifier: String?,
        windowTitle: String?,
        url: URL?,
        settings: IrizSettings
    ) -> Bool {
        if let bundleIdentifier,
           bundleIdentifier == Bundle.main.bundleIdentifier || settings.excludedBundleIdentifiers.contains(bundleIdentifier) {
            return true
        }
        if let host = url?.host?.lowercased() {
            if settings.excludedDomains.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
                return true
            }
        }
        let title = windowTitle?.localizedLowercase ?? ""
        let sensitiveTitles = ["authentication", "sign in", "password", "private browsing", "incognito"]
        let customTitles = UserDefaults.standard.stringArray(forKey: "iriz.excludedWindowKeywords") ?? []
        return (sensitiveTitles + customTitles.map(\.localizedLowercase)).contains(where: title.contains)
    }

    static func redactSensitiveText(_ text: String) -> String {
        var value = text
        let patterns = [
            #"\bsk-[A-Za-z0-9_-]{16,}\b"#,
            #"\b(?:\d[ -]*?){13,19}\b"#,
            #"\b\d{3}-\d{2}-\d{4}\b"#,
            #"(?i)(password|passcode|one[- ]time code|verification code)\s*[:=]\s*\S+"#
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            value = expression.stringByReplacingMatches(in: value, range: range, withTemplate: "[REDACTED]")
        }
        return value
    }
}
