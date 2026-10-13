// swift-tools-version: 6.1
import PackageDescription

// The app's own policy, kept where it can be tested.
let package = Package(
    name: "PeeringKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PeeringKit", targets: ["PeeringKit"]),
    ],
    dependencies: [
        .package(path: "../RemoteCore"),
    ],
    targets: [
        .target(
            name: "PeeringKit",
            dependencies: [
                .product(name: "RemoteCore", package: "RemoteCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PeeringKitTests",
            dependencies: ["PeeringKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
