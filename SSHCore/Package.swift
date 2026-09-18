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
// manifest declares. Declaring 17 is a coin flip; declaring 18 is not. The app itself is at 26.5.
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
        // swift-crypto below 4.0, and this project pins 4.5.2, so every target in the Xcode project
        // — the app, both widgets, the Mac host and the probes — resolves swift-crypto to 3.15.1
        // because of it. RemoteCore's 143 tests pass against 3.15.1, and RemoteCore only uses
        // `SHA256` and `P256.KeyAgreement`, but the pin is a consequence of this line and should be
        // revisited if Citadel ever widens its requirement.
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.1"),
        // Declared here rather than left to arrive through Citadel, even though Citadel is what
        // puts it in the graph. `SSHFingerprint` uses `SHA256` directly, and the version bound is
        // the constraint that decides what the *whole Xcode project* resolves to — see the note
        // above. Written down, it is a decision with a reason; inherited, it is a surprise in
        // `Package.resolved` that nobody chose.
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
