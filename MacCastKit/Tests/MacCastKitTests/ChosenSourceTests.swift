import CoreGraphics
import Foundation
import RemoteCore
import Testing

@testable import MacCastKit

/// **Serialised, because the store is a read-modify-write over one key.** Swift Testing runs a
/// suite's tests in parallel, and two of the ones below saving at the same moment lose each
/// other's writes: the second reads the dictionary before the first has written it, and the host
/// the first was remembering is simply gone. The app cannot hit this, because every save is on the
/// main actor and one source is chosen at a time, so this is a property of the test rather than of
/// ``ChosenSourceStore`` and is answered here rather than in the store.
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
        // The window was closed since, and a display can be unplugged: the question is about ids
        // and the catalogue is the answer for every kind of them.
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
        // The state before the Mac has answered: nothing is restored rather than the remembered
        // source being assumed to be there.
        #expect(ChosenSource.restored(.display(1), into: nil) == nil)
    }

    @Test("a source survives the round trip through the defaults")
    func storage() {
        let host = "probe-host-\(UUID().uuidString)"
        #expect(ChosenSourceStore.load(hostID: host) == nil)

        ChosenSourceStore.save(.window(17), hostID: host)
        #expect(ChosenSourceStore.load(hostID: host) == CaptureSource.window(17))

        // Nothing is how a Mac is forgotten, so it opens on whatever it would open on with
        // nothing remembered.
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

        // And what one Mac is left on is not disturbed by the other being forgotten: a source
        // remembered against an id belongs to that id and to nothing else.
        ChosenSourceStore.save(nil, hostID: first)
        #expect(ChosenSourceStore.load(hostID: first) == nil)
        #expect(ChosenSourceStore.load(hostID: second) == CaptureSource.application(402))
    }
}
