// swift-tools-version: 6.1
import PackageDescription

// The app's own policy, kept where it can be tested.
let package = Package(
    name: "MacCastKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MacCastKit", targets: ["MacCastKit"]),
    ],
    dependencies: [
        .package(path: "../RemoteCore"),
    ],
    targets: [
        .target(
            name: "MacCastKit",
            dependencies: [
                .product(name: "RemoteCore", package: "RemoteCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MacCastKitTests",
            dependencies: ["MacCastKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
