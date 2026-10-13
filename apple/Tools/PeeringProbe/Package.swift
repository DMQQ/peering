// swift-tools-version: 6.1
import PackageDescription

// A headless client used to prove the host works before any iOS UI exists.
//
// It is a separate SwiftPM package rather than a target in Peering.xcodeproj on purpose:
// it stays out of the app's build graph, and running it is `swift run` with no scheme,
// destination, or signing involved. It depends on RemoteCore by path — the same code the
// iOS client will use — so anything it proves about the handshake holds for the real client.
let package = Package(
    name: "PeeringProbe",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../RemoteCore"),
    ],
    targets: [
        .executableTarget(
            name: "PeeringProbe",
            dependencies: [.product(name: "RemoteCore", package: "RemoteCore")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The frame validation in `--video-recv` is the part of the probe that cannot be
        // exercised against a real host until the host's capture path runs — and it is
        // exactly the part whose failures are supposed to be distinguishable. Feeding it
        // frames directly is the only way to know the checks fire at all before then.
        .testTarget(
            name: "PeeringProbeTests",
            dependencies: ["PeeringProbe"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
