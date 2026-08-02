import CoreGraphics
import CryptoKit
import Foundation

struct FrameSignature: Equatable, Sendable {
    var pixels: [UInt8]
    var digest: String
}

enum FrameDiffer {
    static func signature(for image: CGImage, width: Int = 32, height: Int = 18) -> FrameSignature? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let digest = SHA256.hash(data: Data(pixels)).map { String(format: "%02x", $0) }.joined()
        return FrameSignature(pixels: pixels, digest: digest)
    }

    static func difference(from lhs: FrameSignature?, to rhs: FrameSignature) -> Double {
        guard let lhs, lhs.pixels.count == rhs.pixels.count else { return 1 }
        let total = zip(lhs.pixels, rhs.pixels).reduce(0.0) { partial, pair in
            partial + abs(Double(pair.0) - Double(pair.1)) / 255
        }
        return total / Double(rhs.pixels.count)
    }
}
