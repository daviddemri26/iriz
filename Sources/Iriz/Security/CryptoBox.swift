import CryptoKit
import Foundation

enum CryptoBoxError: LocalizedError {
    case invalidKey
    case invalidCiphertext

    var errorDescription: String? {
        switch self {
        case .invalidKey: "The encryption key is invalid."
        case .invalidCiphertext: "The encrypted data could not be opened."
        }
    }
}

struct CryptoBox: Sendable {
    private let key: SymmetricKey

    init(keyData: Data) throws {
        guard keyData.count == 32 else { throw CryptoBoxError.invalidKey }
        self.key = SymmetricKey(data: keyData)
    }

    init(key: SymmetricKey) {
        self.key = key
    }

    static func generateKeyData() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    func seal(_ data: Data, authenticating context: Data = Data()) throws -> Data {
        let box = try AES.GCM.seal(data, using: key, authenticating: context)
        guard let combined = box.combined else { throw CryptoBoxError.invalidCiphertext }
        return combined
    }

    func open(_ data: Data, authenticating context: Data = Data()) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(box, using: key, authenticating: context)
        } catch {
            throw CryptoBoxError.invalidCiphertext
        }
    }
}

enum ApplicationDirectories {
    static func applicationSupport(fileManager: FileManager = .default) throws -> URL {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = root.appendingPathComponent("Iriz", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

enum SecurityBootstrap {
    static func keyData(account: String, keychain: KeychainStore = .shared) throws -> Data {
        if let existing = try keychain.readData(account: account), existing.count == 32 {
            return existing
        }
        let generated = CryptoBox.generateKeyData()
        try keychain.writeData(generated, account: account)
        return generated
    }
}
