// swift-tools-version: 6.1
import PackageDescription

// The SSH client: transport, credentials, known hosts, and the SFTP reads the folder tree needs.
//
// Deliberately *not* part of RemoteCore, for two reasons. RemoteCore is the module the macOS host
// shares, and a client that dials arbitrary servers is not something a host has any use for — it
// would put swift-nio, NIOSSH and BigInt into every host build to no purpose. And RemoteCore's own
// header forbids anything beyond what both platforms have to hand; this needs a network stack of
// its own.
//
// The second reason is the one that matters more, and it is written on `ClientTransport` already:
// the app target defaults to `MainActor` isolation, and a NIO channel handler that infers
// `@MainActor` is a crash rather than a compile error the day a callback arrives on an event loop.
// A package is nonisolated unless it says otherwise, and v6 language mode makes that something the
// compiler checks instead of something a comment hopes for.
//
// iOS 18 rather than RemoteCore's 17: Citadel gates `withPTY` and its TTY output behind
// `@available(macOS 15.0, *)`, and a trailing `*` does not raise the iOS floor — so the
// `AsyncThrowingStream.makeStream()` calls inside it are checked against whatever iOS floor this
// manifest declares. Declaring 17 is a coin flip; declaring 18 is not. The app itself is at 18.0.
let package = Package(
    name: "SSHCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "SSHCore", targets: ["SSHCore"]),
    ],
    dependencies: [
        // The wire vocabulary the browser draws: `RemoteDirectoryEntry` and `RemoteFilePreview`
        // are what a folder and a file *are* in this app, and the SSH browser hands the same two
        // to the same panel the Mac's browser does. The dependency only points one way — RemoteCore
        // is the module both platforms share and still knows nothing about SSH, NIO or Citadel.
        .package(path: "../RemoteCore"),
        // Pure Swift, so it links into iOS with no C library to build or sign, and it brings the
        // three things that would otherwise be a month of work: a PTY channel with a stdin writer
        // that can also resize, an SFTP client, and a host-key validator the handshake can be held
        // open on while a human reads a fingerprint.
        //
        // It costs one thing worth naming here rather than in a commit message: Citadel requires
        // swift-crypto below 4.0, and that bound is the one that binds. Every target in the Xcode
        // project (the app, both widgets, the Mac host and the probes) resolves swift-crypto
        // 3.15.1 because of it, while everything that does not pull Citadel in (RemoteCore,
        // MacCastKit and both probes, built by `swift test`) resolves 4.5.2. The line below this
        // one is the same bound and changes nothing, which was measured rather than assumed:
        // widening it leaves the resolution at 3.15.1, and narrowing it produces SwiftPM's own
        // complaint naming Citadel. So the suites and the shipped app build against different
        // majors of the library that backs swift-certificates' X509, which is where the work that
        // matters happens. The way out is upstream, and neither Citadel's newest release nor the
        // swift-nio-ssh fork this project depends on has widened its requirement yet.
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.1"),
        // Declared here rather than left to arrive through Citadel, even though Citadel is what
        // puts it in the graph: `SSHFingerprint` and `SSHPasscodeStore` use `SHA256` directly, so
        // this target needs the product whether or not anything else does. The bound is written
        // out because a version nobody chose is a surprise in `Package.resolved`, not because it
        // decides anything; the note above is the measured account of what does.
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
