// swift-tools-version: 6.1
import PackageDescription

// Not part of RemoteCore: the host shares that module and has no use for swift-nio, NIOSSH and BigInt. A package is nonisolated by default, which keeps NIO channel handlers from inferring `@MainActor` and crashing.
// iOS 18 rather than 17: Citadel gates `withPTY` behind `@available(macOS 15.0, *)`, and the trailing `*` does not raise the iOS floor, so its `AsyncThrowingStream.makeStream()` calls are checked against this floor.
let package = Package(
    name: "SSHCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "SSHCore", targets: ["SSHCore"]),
    ],
    dependencies: [
        // RemoteCore holds the shared wire vocabulary and knows nothing about SSH; the dependency points one way.
        .package(path: "../RemoteCore"),
        // Citadel requires swift-crypto below 4.0, so the app and widgets resolve 3.15.1 while RemoteCore and MacCastKit tests resolve 4.5.2. Widening the bound below changes nothing and narrowing it makes SwiftPM complain; the way out is upstream.
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.1"),
        // Declared directly because `SSHFingerprint` and `SSHPasscodeStore` use `SHA256`.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.12.3"..<"4.0.0"),
    ],
    targets: [
        .target(
            name: "SSHCore",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "RemoteCore", package: "RemoteCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SSHCoreTests",
            dependencies: ["SSHCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
