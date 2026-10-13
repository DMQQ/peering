// swift-tools-version: 6.1
import PackageDescription

// What the iPhone and the watch say to each other, kept free of UIKit and WatchKit so both can link it and a test can run it.
let package = Package(
    name: "WatchLink",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [
        .library(name: "WatchLink", targets: ["WatchLink"]),
    ],
    targets: [
        .target(name: "WatchLink", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "WatchLinkTests", dependencies: ["WatchLink"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
