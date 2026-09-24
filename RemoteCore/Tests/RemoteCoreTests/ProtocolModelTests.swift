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

    @Test("managed virtual display metadata survives the wire and descriptor copies")
    func managedVirtualDisplayMetadata() throws {
        let descriptor = CaptureSourceDescriptor(
            kind: .display,
            title: "Peering Display 2",
            source: .display(42),
            pixelSize: CGSize(width: 2_796, height: 1_290),
            isManagedVirtualDisplay: true
        )

        #expect(try roundTrip(descriptor).isManagedVirtualDisplay)

        let thumbnail = SourceThumbnail(width: 20, height: 10, jpegData: Data([1, 2, 3]))
        #expect(descriptor.withThumbnail(thumbnail).isManagedVirtualDisplay)
    }

    @Test("a descriptor from before managed display metadata reads as unmanaged")
    func legacyDescriptorIsNotManaged() throws {
        let descriptor = CaptureSourceDescriptor(
            kind: .display,
            title: "Built-in Display",
            source: .display(1),
            pixelSize: CGSize(width: 3_024, height: 1_964)
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(descriptor)) as? [String: Any]
        )
        object.removeValue(forKey: "isManagedVirtualDisplay")

        let decoded = try JSONDecoder().decode(
            CaptureSourceDescriptor.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(!decoded.isManagedVirtualDisplay)
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

    @Test("a thumbnail rides on the descriptor and comes back")
    func thumbnailRoundTrip() throws {
        let picture = SourceThumbnail(width: 320, height: 200, jpegData: Data([0xff, 0xd8, 0xff]))
        let app = CaptureSourceDescriptor(
            kind: .application,
            title: "Xcode",
            thumbnail: picture,
            source: .application(42),
            pixelSize: CGSize(width: 1200, height: 800)
        )

        let decoded = try roundTrip(app)
        #expect(decoded.thumbnail == picture)
        #expect(decoded.thumbnail?.width == 320)
        // The picture is part of the value, which is what makes the host's per-session
        // "already sent this catalogue" check notice a set of new thumbnails.
        #expect(decoded == app)
    }

    @Test("a descriptor with no thumbnail carries no key")
    func noThumbnailIsAbsent() throws {
        let app = CaptureSourceDescriptor(
            kind: .application, title: "Notes", source: .application(7),
            pixelSize: CGSize(width: 800, height: 600)
        )
        #expect(app.thumbnail == nil)
        // Decoded from a payload written by a host that has never taken one, which is what a
        // client predating this field sends itself.
        #expect(try roundTrip(app).thumbnail == nil)
    }

    @Test("withThumbnail attaches, and a nil leaves the descriptor alone")
    func attaching() {
        let app = CaptureSourceDescriptor(
            kind: .application, title: "Notes", source: .application(7),
            pixelSize: CGSize(width: 800, height: 600)
        )
        let picture = SourceThumbnail(width: 20, height: 10, jpegData: Data([1, 2, 3]))

        let withPicture = app.withThumbnail(picture)
        #expect(withPicture.thumbnail == picture)
        // Everything else survives the copy, or the catalogue would silently lose a row's name
        // the moment a picture landed on it.
        #expect(withPicture.id == app.id)
        #expect(withPicture.title == app.title)
        #expect(withPicture.pixelSize == app.pixelSize)

        #expect(app.withThumbnail(nil) == app)
    }

    @Test("an oversize thumbnail costs its tile and not the catalogue")
    func oversizeThumbnailIsDropped() throws {
        let app = CaptureSourceDescriptor(
            kind: .application, title: "Notes", source: .application(7),
            pixelSize: CGSize(width: 800, height: 600)
        )
        let oversize = Data(repeating: 1, count: SourceThumbnail.maximumByteCount + 1)

        // The type itself refuses it, which is where the limit is enforced.
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                SourceThumbnail.self,
                from: JSONSerialization.data(withJSONObject: [
                    "width": 10, "height": 10,
                    "jpegData": oversize.base64EncodedString(),
                ])
            )
        }

        // And the descriptor survives it, which is the half that matters: a throw here would
        // cost the client its whole source list, and with it the session, over a picture.
        guard var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(app)
        ) as? [String: Any] else {
            Issue.record("the descriptor did not encode to an object")
            return
        }
        json["thumbnail"] = [
            "width": 10, "height": 10,
            "jpegData": oversize.base64EncodedString(),
        ]
        let decoded = try JSONDecoder().decode(
            CaptureSourceDescriptor.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
        #expect(decoded.thumbnail == nil)
        #expect(decoded.title == "Notes")
        #expect(decoded.source == .application(7))
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
            .setVideoEnabled(true),
            .setVideoEnabled(false),
            .lockScreen,
            .requestClipboard,
            .pushClipboard(text: "héllo 👋 世界"),
            .addVirtualDisplay(name: "Build", width: 1_290, height: 2_796, startLandscape: true),
            .removeVirtualDisplay(displayID: 42),
            .renameVirtualDisplay(displayID: 42, name: "Preview"),
        ]

        for command in commands {
            #expect(try roundTrip(command) == command)
        }
    }

    /// The wire shape, pinned, because both ends have to agree on it and because the failure of
    /// getting it wrong is not symmetric anywhere. A Mac that does not know this command fails
    /// on it rather than ignoring it, which is why a client may only send it to one that has
    /// said it understands it, see ``ServerHello/supportsVideoPause``.
    @Test("the video switch encodes as one keyed payload")
    func videoSwitchEncoding() throws {
        let encoded = try JSONEncoder().encode(RemoteCommand.setVideoEnabled(false))
        #expect(String(decoding: encoded, as: UTF8.self) == #"{"setVideoEnabled":{"_0":false}}"#)
    }

    /// An absolute state produced by a tab switch, so it must neither be merged with another
    /// one nor held back for the coalescing window: a Mac that goes on producing frames for
    /// another 16 ms is the thing the command exists to stop.
    @Test("the video switch is neither merged nor delayed")
    func videoSwitchIsNotCoalesced() {
        #expect(RemoteCommand.setVideoEnabled(false).coalescing == Coalescing.none)
        #expect(RemoteCommand.setVideoEnabled(true).coalescing == Coalescing.none)
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

    /// Losing any of these leaves the host stuck, with a button held down or a key repeating, or
    /// leaves a request that is sent exactly once stranded with nothing to repeat it. A video
    /// switch is the second kind, and it is the same shape as ``setCaptureSource(_:)``: a
    /// resume that never arrives is a client waiting for a picture that never starts, and a
    /// pause that never arrives is a Mac capturing for somebody who is looking elsewhere.
    @Test("press and release events are never dropped")
    func criticalEvents() {
        for command: RemoteCommand in [
            .mouseDown(button: .left), .mouseUp(button: .left),
            .keyDown(keyCode: 0, modifiers: []), .keyUp(keyCode: 0, modifiers: []),
            .setPrivacyMode(enabled: true),
            .setVideoEnabled(false), .setVideoEnabled(true),
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
            // Stopping the picture changes what the Mac is showing, not what it is doing: a
            // session in observe mode is exactly the one that goes on watching a Mac it is not
            // allowed to touch.
            .setVideoEnabled(false),
            .refreshSpacePreviews,
            // Asking for pictures changes what the picker shows and nothing about the Mac, so
            // a session in observe mode may do it — the same reading ``refreshSpacePreviews``
            // gets two lines up.
            .refreshSourceThumbnails,
            .setPrivacyMode(enabled: true),
            .lockScreen,
            .requestClipboard,
            .pushClipboard(text: "hello"),
            .addVirtualDisplay(name: "", width: 1_179, height: 2_556, startLandscape: false),
            .removeVirtualDisplay(displayID: 42),
            .renameVirtualDisplay(displayID: 42, name: "Phone"),
        ]
        #expect(sessionControls.allSatisfy { !$0.isUserInput })
    }

    @Test("virtual display management requests are sent immediately and are not input events")
    func virtualDisplayManagementClassification() {
        let commands: [RemoteCommand] = [
            .addVirtualDisplay(name: "", width: 1_290, height: 2_796, startLandscape: true),
            .removeVirtualDisplay(displayID: 42),
            .renameVirtualDisplay(displayID: 42, name: "Build"),
        ]

        for command in commands {
            #expect(command.coalescing == .none)
            #expect(!command.isUserInput)
            #expect(!command.isCritical)
        }
    }
}

@Suite("Mosaic")
struct MosaicWireTests {
    private func tile(
        _ source: CaptureSource,
        _ x: Double,
        _ y: Double,
        size: Double = 0.5
    ) -> MosaicTile {
        MosaicTile(source: source, rect: NormalizedRect(x: x, y: y, width: size, height: size))
    }

    private func layout(
        _ tiles: [MosaicTile],
        canvas: CGSize = CGSize(width: 1920, height: 1080),
        frameRate: Int = 15
    ) -> MosaicLayout {
        MosaicLayout(canvas: canvas, tiles: tiles, frameRate: frameRate)
    }

    @Test("round-trips through JSON")
    func codec() throws {
        let value = layout([tile(.window(42), 0, 0), tile(.application(9), 0.5, 0.5)])
        let encoded = try JSONEncoder().encode(CaptureSource.mosaic(value))
        #expect(try JSONDecoder().decode(CaptureSource.self, from: encoded) == .mosaic(value))
    }

    @Test("a name that survives a relaunch, and that tells two arrangements apart")
    func identity() {
        let one = layout([tile(.window(42), 0, 0)])
        let again = layout([tile(.window(42), 0, 0)])
        // **The reason this is written by hand rather than with `Hasher`.** The name is what a
        // persisted selection and the client's picture identity are kept by, so the same
        // arrangement has to answer the same string in a later process.
        #expect(CaptureSource.mosaic(one).stableID == CaptureSource.mosaic(again).stableID)

        // Moved, reordered, or drawn on a different canvas: three different pictures.
        #expect(CaptureSource.mosaic(one).stableID != CaptureSource.mosaic(layout([tile(.window(42), 0.5, 0)])).stableID)
        let two = [tile(.window(42), 0, 0), tile(.application(9), 0.5, 0)]
        let swapped = [tile(.application(9), 0.5, 0), tile(.window(42), 0, 0)]
        #expect(CaptureSource.mosaic(layout(two)).stableID != CaptureSource.mosaic(layout(swapped)).stableID)
        #expect(CaptureSource.mosaic(one).stableID != CaptureSource.mosaic(
            layout([tile(.window(42), 0, 0)], canvas: CGSize(width: 1280, height: 720))
        ).stableID)

        // And the frame rate is *not* part of it: the same arrangement redrawn faster is the
        // same arrangement, and a client that changed the rate has not changed the picture.
        #expect(CaptureSource.mosaic(one).stableID == CaptureSource.mosaic(layout([tile(.window(42), 0, 0)], frameRate: 30)).stableID)
    }

    @Test("a canvas is fixed, so the picture identity treats it as a display")
    func doesNotMoveOnItsOwn() {
        // The one-line decision with no compile error behind it: a mosaic is not a window. Its
        // tiles are dragged around inside a canvas that never changes shape, so the client keeps
        // the zoom and the pan it was given rather than resetting them under a moving finger.
        #expect(CaptureSource.mosaic(layout([tile(.window(42), 0, 0)])).contentMovesOnItsOwn == false)
    }

    @Test("the host trims what a client asks for rather than refusing it")
    func limits() {
        // More tiles than a Mac will run streams for: the first ones are kept, which are the
        // ones the user put there. The alternative is a Mac asked to melt by a device it paired
        // with and does not control.
        let many = (0..<9).map { tile(.window(UInt32($0 + 1)), Double($0) / 10, 0, size: 0.1) }
        #expect(layout(many).validated?.tiles.count == MosaicLayout.maximumTileCount)

        // A canvas over the pixel budget is scaled to fit, keeping its shape: a 4K canvas is
        // still 16:9 afterwards, and no larger than the budget.
        let huge = layout([tile(.display(1), 0, 0, size: 1)])
        let trimmed = MosaicLayout(
            canvas: CGSize(width: 7680, height: 4320),
            tiles: huge.tiles,
            frameRate: 60
        ).validated
        #expect(trimmed != nil)
        if let trimmed {
            let pixels = trimmed.canvas.width * trimmed.canvas.height
            #expect(pixels <= CGFloat(MosaicLayout.maximumCanvasPixels))
            #expect(abs(trimmed.canvas.width / trimmed.canvas.height - 16.0 / 9.0) < 0.01)
            // Even, because the encoder rounds down to even and the client's rects were
            // measured against what it asked for.
            #expect(trimmed.canvas.width.truncatingRemainder(dividingBy: 2) == 0)
            #expect(trimmed.canvas.height.truncatingRemainder(dividingBy: 2) == 0)
            #expect(trimmed.frameRate == MosaicLayout.maximumFrameRate)
        }

        // A rate that is a slideshow or a space heater is pulled back rather than refused.
        #expect(layout([tile(.window(1), 0, 0)], frameRate: 1).validated?.frameRate == MosaicLayout.minimumFrameRate)
        #expect(layout([tile(.window(1), 0, 0)], frameRate: 0).validated?.frameRate == MosaicLayout.minimumFrameRate)

        // Nothing to draw is not a mosaic.
        #expect(layout([]).validated == nil)
    }

    @Test("a rectangle cannot describe anything outside its canvas")
    func rectClamping() {
        // The origin is clamped against what the size leaves, not against 1: a rect of
        // x 0.9 with width 0.5 would otherwise run to 1.4 and be drawn past the edge.
        let overhanging = NormalizedRect(x: 0.9, y: 0.9, width: 0.5, height: 0.5).clamped
        #expect(overhanging.x == 0.5)
        #expect(overhanging.y == 0.5)
        #expect(overhanging.x + overhanging.width <= 1)
        #expect(overhanging.y + overhanging.height <= 1)

        // A rect wider than the canvas is the canvas, and one that is nothing is empty.
        #expect(NormalizedRect(x: 0, y: 0, width: 4, height: 4).clamped == NormalizedRect(x: 0, y: 0, width: 1, height: 1))
        #expect(NormalizedRect(x: 0.2, y: 0.2, width: 0, height: 0.4).clamped.width == 0)

        // The host's side of it: a normalized rect becomes pixels in the canvas.
        let rect = NormalizedRect(x: 0.25, y: 0.5, width: 0.5, height: 0.5)
        #expect(rect.pixels(in: CGSize(width: 1920, height: 1080)) == CGRect(x: 480, y: 540, width: 960, height: 540))

        // And the client's side: the point where two tiles meet belongs to exactly one.
        let left = NormalizedRect(x: 0, y: 0, width: 0.5, height: 1)
        let right = NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1)
        #expect(left.contains(NormalizedPoint(x: 0.49, y: 0.5)))
        #expect(!left.contains(NormalizedPoint(x: 0.5, y: 0.5)))
        #expect(right.contains(NormalizedPoint(x: 0.5, y: 0.5)))
    }

    @Test("an older Mac's hello still decodes, and reads as no")
    func capabilityIsAdditive() throws {
        // The field is optional precisely so that a Mac built before it existed sends a hello
        // this build reads as "no mosaic here", rather than failing to decode at the door.
        let older = """
            {"serverID":"mac","hostName":"Studio","protocolVersion":17,"alreadyPaired":true}
            """
        let decoded = try JSONDecoder().decode(ServerHello.self, from: Data(older.utf8))
        #expect(decoded.supportsMosaic == nil)
        #expect(decoded.supportsMosaic != true)

        // And one that has it says so, through a round trip.
        let hello = ServerHello(
            serverID: "mac", hostName: "Studio", protocolVersion: 17,
            alreadyPaired: true, supportsMosaic: true
        )
        let encoded = try JSONEncoder().encode(hello)
        #expect(try JSONDecoder().decode(ServerHello.self, from: encoded).supportsMosaic == true)
    }
}
