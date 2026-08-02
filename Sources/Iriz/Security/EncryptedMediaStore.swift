import Foundation

actor EncryptedMediaStore {
    enum MediaError: LocalizedError {
        case missingMedia
        case invalidIdentifier

        var errorDescription: String? {
            switch self {
            case .missingMedia: "The requested media is no longer available."
            case .invalidIdentifier: "The media identifier is invalid."
            }
        }
    }

    private let directory: URL
    private let crypto: CryptoBox
    private let fileManager: FileManager

    init(
        directory: URL? = nil,
        keyData: Data? = nil,
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager
        let root = try directory ?? ApplicationDirectories.applicationSupport(fileManager: fileManager)
            .appendingPathComponent("Media", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        self.directory = root
        let resolvedKey = try keyData ?? SecurityBootstrap.keyData(account: KeychainAccounts.mediaKey)
        self.crypto = try CryptoBox(keyData: resolvedKey)
    }

    func store(
        _ data: Data,
        fileExtension: String,
        expiresAt: Date = Date().addingTimeInterval(24 * 60 * 60)
    ) throws -> String {
        let safeExtension = fileExtension
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        let identifier = "\(UUID().uuidString)_\(Int(expiresAt.timeIntervalSince1970)).\(safeExtension).iriz"
        let context = Data(identifier.utf8)
        let encrypted = try crypto.seal(data, authenticating: context)
        try encrypted.write(to: directory.appendingPathComponent(identifier), options: [.atomic, .completeFileProtection])
        return identifier
    }

    func read(identifier: String) throws -> Data {
        guard !identifier.contains("/"), !identifier.contains("..") else {
            throw MediaError.invalidIdentifier
        }
        let url = directory.appendingPathComponent(identifier)
        guard fileManager.fileExists(atPath: url.path) else { throw MediaError.missingMedia }
        let encrypted = try Data(contentsOf: url)
        return try crypto.open(encrypted, authenticating: Data(identifier.utf8))
    }

    func temporaryDecryptedFile(identifier: String, preferredExtension: String) throws -> URL {
        let data = try read(identifier: identifier)
        let root = fileManager.temporaryDirectory.appendingPathComponent("Iriz-Decrypted", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("\(UUID().uuidString).\(preferredExtension)")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    func remove(identifier: String) throws {
        guard !identifier.contains("/"), !identifier.contains("..") else {
            throw MediaError.invalidIdentifier
        }
        let url = directory.appendingPathComponent(identifier)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    @discardableResult
    func purgeExpired(now: Date = Date()) throws -> Int {
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var removed = 0
        for file in files where file.pathExtension == "iriz" {
            let components = file.deletingPathExtension().deletingPathExtension().lastPathComponent.split(separator: "_")
            guard let timestamp = components.last.flatMap({ TimeInterval($0) }) else { continue }
            if Date(timeIntervalSince1970: timestamp) <= now {
                try fileManager.removeItem(at: file)
                removed += 1
            }
        }
        return removed
    }

    func removeTemporaryFiles() throws {
        let root = fileManager.temporaryDirectory.appendingPathComponent("Iriz-Decrypted", isDirectory: true)
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
    }
}
