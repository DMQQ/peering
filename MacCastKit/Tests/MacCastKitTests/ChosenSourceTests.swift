import CoreGraphics
import Foundation
import RemoteCore
import Testing

@testable import MacCastKit

/// Serialised: the store is a read-modify-write over one key, so parallel saves lose each other's writes. The app cannot hit this (saves are on the main actor).
@Suite("Remembering a source", .serialized)
struct ChosenSourceTests {
    private func descriptor(
        _ source: CaptureSource,
        kind: CaptureSourceDescriptor.Kind = .window,
        title: String = "A window"
    ) -> CaptureSourceDescriptor {
        CaptureSourceDescriptor(
            kind: kind,
            title: title,
            source: source,
            pixelSize: CGSize(width: 800, height: 600)
        )
    }

    @Test("a source the Mac still has comes back, whichever kind it is")
    func stillThere() {
        let catalog = CaptureCatalog(
            displays: [descriptor(.display(1), kind: .display, title: "Built-in Display")],
            applications: [descriptor(.application(402), title: "Xcode")],
            windows: [descriptor(.window(42))]
        )
        #expect(ChosenSource.restored(.display(1), into: catalog) == CaptureSource.display(1))
        #expect(ChosenSource.restored(.application(402), into: catalog) == CaptureSource.application(402))
        #expect(ChosenSource.restored(.window(42), into: catalog) == CaptureSource.window(42))
    }

    @Test("a source the Mac no longer has does not come back")
    func gone() {
        let catalog = CaptureCatalog(
            displays: [descriptor(.display(1), kind: .display)],
            applications: [],
            windows: []
        )
        #expect(ChosenSource.restored(.window(42), into: catalog) == nil)
        #expect(ChosenSource.restored(.application(402), into: catalog) == nil)
        #expect(ChosenSource.restored(.display(2), into: catalog) == nil)
    }

    @Test("nothing remembered, and no catalogue at all, are both nothing")
    func nothing() {
        let catalog = CaptureCatalog(
            displays: [descriptor(.display(1), kind: .display)],
            applications: [],
            windows: []
        )
        #expect(ChosenSource.restored(nil, into: catalog) == nil)
        #expect(ChosenSource.restored(.display(1), into: nil) == nil)
    }

    @Test("a source survives the round trip through the defaults")
    func storage() {
        let host = "probe-host-\(UUID().uuidString)"
        #expect(ChosenSourceStore.load(hostID: host) == nil)

        ChosenSourceStore.save(.window(17), hostID: host)
        #expect(ChosenSourceStore.load(hostID: host) == CaptureSource.window(17))

        ChosenSourceStore.save(nil, hostID: host)
        #expect(ChosenSourceStore.load(hostID: host) == nil)
    }

    @Test("one Mac's source is not another Mac's")
    func perHost() {
        let first = "probe-host-\(UUID().uuidString)"
        let second = "probe-host-\(UUID().uuidString)"
        ChosenSourceStore.save(.display(1), hostID: first)
        ChosenSourceStore.save(.application(402), hostID: second)

        #expect(ChosenSourceStore.load(hostID: first) == CaptureSource.display(1))
        #expect(ChosenSourceStore.load(hostID: second) == CaptureSource.application(402))

        ChosenSourceStore.save(nil, hostID: first)
        #expect(ChosenSourceStore.load(hostID: first) == nil)
        #expect(ChosenSourceStore.load(hostID: second) == CaptureSource.application(402))
    }
}
