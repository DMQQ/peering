// swift-tools-version: 6.1
import PackageDescription

// RemoteCore is shared by the macOS host and the iOS client, so it may only use
// frameworks present on both: Foundation, Crypto, Security, Network and CoreGraphics.
// Anything macOS-only (ScreenCaptureKit, VideoToolbox, AppKit) belongs in the host
// target — this module is compiled for iOS too, where those frameworks do not exist.
//
// swift-certificates is the one external dependency, and it is shared rather than
// host-only because both sides mint a self-signed identity and pin the peer's SPKI.
let package = Package(
    name: "RemoteCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RemoteCore", targets: ["RemoteCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.20.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.7.2"),
    ],
    targets: [
        .target(
            name: "RemoteCore",
            dependencies: [
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RemoteCoreTests",
            dependencies: ["RemoteCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
