import Foundation

/// Writes payloads that are already encrypted by Iriz. File protection is kept
/// when the volume supports it; some macOS sandbox and temporary volumes reject
/// that attribute even though an atomic write itself is allowed.
enum EncryptedFileWriter {
    static func write(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch let error as CocoaError where error.code == .fileWriteNoPermission {
            // Confidentiality still comes from the authenticated AES-GCM envelope.
            // A genuinely non-writable destination fails again on this attempt.
            try data.write(to: url, options: [.atomic])
        }
    }
}
