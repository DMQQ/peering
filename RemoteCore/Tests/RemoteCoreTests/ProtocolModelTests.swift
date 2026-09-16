import CoreGraphics
import Foundation
import Testing

@testable import RemoteCore

@Suite("CaptureSource")
struct CaptureSourceTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    @Test("round-trips every case through JSON")
    func codec() throws {
        #expect(try roundTrip(CaptureSource.display(1)) == .display(1))
        #expect(try roundTrip(CaptureSource.application(4242)) == .application(4242))
        #expect(try roundTrip(CaptureSource.window(98_765)) == .window(98_765))
    }

    @Test("stableID distinguishes kinds that share a numeric id")
    func stableIDs() {
        // A display with id 1 and a window with id 1 are different things, so their
        // identifiers must not collide in the client's picker.
        #expect(CaptureSource.display(1).stableID != CaptureSource.window(1).stableID)
        #expect(CaptureSource.display(1).stableID == "display:1")
        #expect(CaptureSource.application(-1).stableID == "application:-1")
    }

    @Test("descriptor id is derived from the source")
    func descriptorIdentity() {
        let descriptor = CaptureSourceDescriptor(
            kind: .window,
            title: "ContentView.swift",
            subtitle: "1200×800",
            source: .window(42),
            pixelSize: CGSize(width: 1200, height: 800)
        )
        #expect(descriptor.id == "window:42")
    }

    @Test("catalog looks a descriptor back up by source")
    func catalogLookup() {
        let display = CaptureSourceDescriptor(
            kind: .display, title: "Built-in Display", source: .display(1),
            pixelSize: CGSize(width: 2560, height: 1440)
        )
        let app = CaptureSourceDescriptor(
            kind: .application, title: "Xcode", subtitle: "3 windows", source: .application(99),
            pixelSize: CGSize(width: 1600, height: 1000)
        )
        let catalog = CaptureCatalog(displays: [display], applications: [app], windows: [])

        #expect(catalog.all.count == 2)
        #expect(catalog.descriptor(for: .application(99)) == app)
        #expect(catalog.descriptor(for: .display(2)) == nil)
        #expect(try! roundTrip(catalog) == catalog)
    }

    @Test("application metadata and bounded icon round-trip")
    func applicationMetadata() throws {
        let icon = Data([0x89, 0x50, 0x4e, 0x47])
        let app = CaptureSourceDescriptor(
            kind: .application,
            title: "Xcode",
            bundleIdentifier: "com.apple.dt.Xcode",
            iconPNGData: icon,
            source: .application(42),
            pixelSize: CGSize(width: 1200, height: 800)
        )

        let decoded = try roundTrip(app)
        #expect(decoded.bundleIdentifier == "com.apple.dt.Xcode")
        #expect(decoded.iconPNGData == icon)

        let tooLarge = Data(repeating: 1, count: CaptureSourceDescriptor.maximumIconByteCount + 1)
        let bounded = CaptureSourceDescriptor(
            kind: .application,
            title: "Large icon",
            iconPNGData: tooLarge,
            source: .application(43),
            pixelSize: CGSize(width: 1, height: 1)
        )
        #expect(bounded.iconPNGData == nil)
    }

    @Test("catalog separates installed apps and filters running duplicates")
    func installedApplications() throws {
        let running = CaptureSourceDescriptor(
            kind: .application,
            title: "Notes",
            bundleIdentifier: "com.apple.Notes",
            source: .application(9),
            pixelSize: CGSize(width: 800, height: 600)
        )
        let notes = InstalledApplicationDescriptor(
            bundleIdentifier: "com.apple.Notes",
            title: "Notes"
        )
        let editor = InstalledApplicationDescriptor(
            bundleIdentifier: "com.example.Editor",
            title: "Editor"
        )
        let catalog = CaptureCatalog(applications: [running], installedApplications: [notes, editor])

        #expect(catalog.installedApplicationsNotRunning == [editor])
        #expect(try roundTrip(catalog) == catalog)
    }

    @Test("new decoder accepts a catalog sent before application metadata existed")
    func legacyCatalogDecode() throws {
        let json = #"{"displays":[],"applications":[],"windows":[]}"#.data(using: .utf8)!
        let catalog = try JSONDecoder().decode(CaptureCatalog.self, from: json)
        #expect(catalog.installedApplications.isEmpty)
    }

    @Test("installed application count is capped")
    func installedApplicationCountLimit() {
        let applications = (0..<(CaptureCatalog.maximumInstalledApplicationCount + 10)).map {
            InstalledApplicationDescriptor(bundleIdentifier: "com.example.app\($0)", title: "App \($0)")
        }
        let catalog = CaptureCatalog(installedApplications: applications)
        #expect(catalog.installedApplications.count == CaptureCatalog.maximumInstalledApplicationCount)
    }

    @Test("space info round-trips a desktop list per display")
    func spaceInfoRoundTrip() throws {
        let info = SpaceInfo(displays: [
            SpaceDisplay(displayID: 1, count: 2, current: 2, previews: [
                SpacePreview(index: 2, width: 320, height: 200, jpegData: Data([1, 2, 3]))
            ]),
            SpaceDisplay(displayID: 2, count: 3, current: 1),
        ])

        #expect(try roundTrip(info) == info)
    }

    /// The flat properties predate a second screen. They describe the first — the main — display,
    /// so that everything written before this change keeps meaning what it meant.
    @Test("flat accessors describe the main display")
    func spaceInfoDerivedAccessors() {
        let info = SpaceInfo(displays: [
            SpaceDisplay(displayID: 1, count: 2, current: 2, previews: [
                SpacePreview(index: 1, width: 320, height: 200, jpegData: Data([9]))
            ]),
            SpaceDisplay(displayID: 2, count: 3, current: 1, previews: [
                SpacePreview(index: 3, width: 320, height: 200, jpegData: Data([8]))
            ]),
        ])

        #expect(info.count == 2)
        #expect(info.current == 2)
        #expect(info.totalCount == 5)
        // Flattened across screens, so a preview is never lost by looking at the wrong one.
        #expect(info.previews.count == 2)
    }

    /// A deck built before this type described more than one display sends the old flat shape.
    /// Refusing it would take the whole catalogue — and with it the session — down over a
    /// thumbnail.
    @Test("space info accepts the shape sent before a Mac had two screens")
    func legacySpaceInfoDecode() throws {
        let json = #"""
        {"count":3,"current":2,"previews":[{"index":1,"width":320,"height":200,"jpegData":"AAEC"}]}
        """#.data(using: .utf8)!

        let info = try JSONDecoder().decode(SpaceInfo.self, from: json)

        #expect(info.displays.count == 1)
        #expect(info.totalCount == 3)
        #expect(info.current == 2)
        #expect(info.previews.count == 1)
    }

    /// Numbering restarts per display, which is why `count` and `current` had to stop being the
    /// only things a payload carried: two screens each have a desktop numbered 1.
    @Test("each display numbers its own desktops")
    func perDisplayNumbering() {
        let info = SpaceInfo(displays: [
            SpaceDisplay(displayID: 1, count: 2, current: 1),
            SpaceDisplay(displayID: 2, count: 3, current: 1),
        ])

        #expect(info.displays.map(\.current) == [1, 1])
        #expect(info.displays.map(\.count) == [2, 3])
    }
}

@Suite("RemoteCommand")
struct RemoteCommandTests {
    private func roundTrip(_ command: RemoteCommand) throws -> RemoteCommand {
        try JSONDecoder().decode(RemoteCommand.self, from: JSONEncoder().encode(command))
    }

    @Test("round-trips every command")
    func codec() throws {
        let commands: [RemoteCommand] = [
            .mouseMove(to: NormalizedPoint(x: 0.25, y: 0.75)),
            .mouseDown(button: .left),
            .mouseUp(button: .right),
            .scroll(dx: 0, dy: -12.5),
            .keyDown(keyCode: 1, modifiers: [.command, .shift]),
            .keyUp(keyCode: 1, modifiers: []),
            .textInput("héllo 👋 世界"),
            .switchSpace(direction: .left),
            // The display is part of the payload: index 1 names a different desktop on every
            // screen, so a round trip that dropped it would still compare unequal.
            .switchToSpace(display: 2, index: 3),
            .joystickMove(dx: -0.5, dy: 0.5),
            .setCaptureSource(.application(4242)),
            .launchApplication(bundleIdentifier: "com.example.Editor"),
            .setPrivacyMode(enabled: true),
            .setPrivacyMode(enabled: false),
            .lockScreen,
            .requestClipboard,
            .pushClipboard(text: "héllo 👋 世界"),
        ]

        for command in commands {
            #expect(try roundTrip(command) == command)
        }
    }

    /// `OptionSet` does not get synthesised `Codable`, so this pins the hand-written one.
    @Test("modifiers encode as a single bitmask")
    func modifierEncoding() throws {
        let encoded = try JSONEncoder().encode(Modifiers([.command, .shift]))
        #expect(String(decoding: encoded, as: UTF8.self) == "\(Modifiers.command.rawValue | Modifiers.shift.rawValue)")
        #expect(try JSONDecoder().decode(Modifiers.self, from: encoded) == [.command, .shift])
    }

    /// Verified against `NSEvent.h`; these values must line up with `CGEventFlags` so the
    /// host's translation is a bare `CGEventFlags(rawValue:)`.
    @Test("modifier bits match the platform layout")
    func modifierBits() {
        #expect(Modifiers.shift.rawValue == 1 << 17)
        #expect(Modifiers.control.rawValue == 1 << 18)
        #expect(Modifiers.option.rawValue == 1 << 19)
        #expect(Modifiers.command.rawValue == 1 << 20)
    }

    /// Coalescing a relative command by "newest wins" would silently drop scroll distance.
    @Test("coalescing treats absolute and relative commands differently")
    func coalescing() {
        #expect(RemoteCommand.mouseMove(to: NormalizedPoint(x: 0, y: 0)).coalescing == .replaceLatest)
        #expect(RemoteCommand.joystickMove(dx: 1, dy: 1).coalescing == .accumulate)
        #expect(RemoteCommand.scroll(dx: 1, dy: 1).coalescing == .accumulate)
    }

    /// Losing any of these leaves the host stuck — a button held down, or a key repeating.
    @Test("press and release events are never dropped")
    func criticalEvents() {
        for command: RemoteCommand in [
            .mouseDown(button: .left), .mouseUp(button: .left),
            .keyDown(keyCode: 0, modifiers: []), .keyUp(keyCode: 0, modifiers: []),
            .setPrivacyMode(enabled: true),
            .lockScreen,
            .pushClipboard(text: "important"),
        ] {
            #expect(command.coalescing == Coalescing.none, "\(command) must not be coalesced")
            #expect(command.isCritical)
        }

        #expect(!RemoteCommand.mouseMove(to: NormalizedPoint(x: 0, y: 0)).isCritical)
    }

    @Test("observe mode can distinguish input from session controls")
    func userInputClassification() {
        let input: [RemoteCommand] = [
            .mouseMove(to: NormalizedPoint(x: 0.5, y: 0.5)),
            .mouseDown(button: .left), .mouseUp(button: .left),
            .scroll(dx: 0, dy: 1), .textInput("hello"),
            .keyDown(keyCode: 0, modifiers: []), .keyUp(keyCode: 0, modifiers: []),
            .switchSpace(direction: .right), .switchToSpace(display: 1, index: 2),
            .joystickMove(dx: 1, dy: 0),
        ]
        #expect(input.allSatisfy { $0.isUserInput })

        let sessionControls: [RemoteCommand] = [
            .setCaptureSource(.display(1)),
            .launchApplication(bundleIdentifier: "com.example.Editor"),
            .setStreamQuality(fps: 0, bitrateKbps: 8_000),
            .refreshSpacePreviews,
            .setPrivacyMode(enabled: true),
            .lockScreen,
            .requestClipboard,
            .pushClipboard(text: "hello"),
        ]
        #expect(sessionControls.allSatisfy { !$0.isUserInput })
    }
}
