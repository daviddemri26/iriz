// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "iriz",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "iriz", targets: ["Iriz"])
    ],
    targets: [
        .executableTarget(
            name: "Iriz",
            path: "Sources/Iriz",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Accelerate"),
                .linkedFramework("AppKit"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("EventKit"),
                .linkedFramework("ImageIO"),
                .linkedFramework("NaturalLanguage"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Speech"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("Vision"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),
        .testTarget(
            name: "IrizTests",
            dependencies: ["Iriz"],
            path: "Tests/IrizTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
