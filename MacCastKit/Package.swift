// swift-tools-version: 6.1
import PackageDescription

// The app's own policy, kept where it can be tested.
//
// **Why this is a package rather than a folder in the app target.** Xcode 27 cannot run this
// project's unit-test action: for a test action it builds every package product as a separate
// dynamic framework, and the Crypto product's target does its packaging and then touches the
// framework without ever running a link step, so X509, RemoteCore and the app all fail to link in
// a cascade. Nothing in the app can fix that, and the tests it blocks are the ones that can be
// wrong silently.
//
// Everything here is therefore plain policy, no UIKit, no SwiftUI, no app bundle, which is what
// lets `swift test` run the suite in seconds, with no Xcode involved. It is built for macOS as well
// as iOS for exactly that reason: `swift test` runs on the Mac, so anything that could only be
// built for iOS could not be tested this way at all.
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
