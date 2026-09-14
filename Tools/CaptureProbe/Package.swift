// swift-tools-version: 6.1
import PackageDescription

// Proves the host's capture and encode path without a client, a window, or a scheme.
//
// The target's sources are **the host's own files**, reached through a symlink at
// `Sources/CaptureProbe/Capture` — not a copy. That is the whole point: a probe that
// compiled its own private version of the encoder would prove that the probe works, and
// the exit criterion for this phase is that the shipped encoder produces a file that
// plays. SwiftPM refuses a target whose path escapes the package root ("target ... is
// outside the package root"), so a symlink is the only way to compile a directory that
// lives in the Xcode target from here.
//
// It depends on RemoteCore by path for the same reason `MacCastProbe` does: those are the
// types the capture code is written against, and testing against anything else would be
// testing a different program.
let package = Package(
    name: "CaptureProbe",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../RemoteCore"),
    ],
    targets: [
        .executableTarget(
            name: "CaptureProbe",
            dependencies: [.product(name: "RemoteCore", package: "RemoteCore")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
