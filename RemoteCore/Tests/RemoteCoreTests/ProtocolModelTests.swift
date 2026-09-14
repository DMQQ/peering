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
            .joystickMove(dx: -0.5, dy: 0.5),
            .setCaptureSource(.application(4242)),
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
        ] {
            #expect(command.coalescing == Coalescing.none, "\(command) must not be coalesced")
            #expect(command.isCritical)
        }

        #expect(!RemoteCommand.mouseMove(to: NormalizedPoint(x: 0, y: 0)).isCritical)
    }
}
