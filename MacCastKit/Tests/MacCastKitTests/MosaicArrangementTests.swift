import CoreGraphics
import Foundation
import RemoteCore
import Testing

@testable import MacCastKit

/// Serialized, like the source-store suite: these tests write one key in `UserDefaults.standard`, and parallel runs read each other's arrangement.
@Suite("Remembering an arrangement", .serialized)
struct MosaicArrangementTests {
    private func descriptor(_ source: CaptureSource, title: String = "A window") -> CaptureSourceDescriptor {
        CaptureSourceDescriptor(
            kind: source.isMosaic ? .display : .window,
            title: title,
            source: source,
            pixelSize: CGSize(width: 800, height: 600)
        )
    }

    @Test("a source the Mac no longer has is dropped, and the rest are kept")
    func thinning() {
        let catalog = CaptureCatalog(
            displays: [descriptor(.display(1))],
            applications: [],
            windows: [descriptor(.window(42)), descriptor(.window(7))]
        )
        let remembered = [
            MosaicChoice(source: .window(42), weight: 2),
            MosaicChoice(source: .window(99)),
            MosaicChoice(source: .display(1)),
        ]
        let restored = MosaicArrangement.restored(remembered, into: catalog)
        #expect(restored.map(\.source) == [.window(42), .display(1)])
        #expect(restored.first?.weight == 2)
    }

    @Test("fewer than two survivors is no mosaic")
    func notEnoughLeft() {
        let catalog = CaptureCatalog(displays: [descriptor(.display(1))], applications: [], windows: [])
        #expect(MosaicArrangement.restored([MosaicChoice(source: .display(1))], into: catalog).isEmpty)
        #expect(MosaicArrangement.restored(
            [MosaicChoice(source: .display(1)), MosaicChoice(source: .window(42))],
            into: catalog
        ).isEmpty)

        #expect(MosaicArrangement.restored([MosaicChoice(source: .display(1))], into: nil).isEmpty)
    }

    @Test("an arrangement survives the round trip through the defaults")
    func storage() {
        let host = "probe-host-\(UUID().uuidString)"
        let choices = [
            MosaicChoice(source: .display(1), weight: 3),
            MosaicChoice(source: .application(402)),
            MosaicChoice(source: .window(17), weight: 2),
        ]

        MosaicArrangementStore.save(choices, hostID: host)
        #expect(MosaicArrangementStore.load(hostID: host) == choices)

        MosaicArrangementStore.save([], hostID: host)
        #expect(MosaicArrangementStore.load(hostID: host).isEmpty)
    }

    @Test("a one-tile arrangement is not stored in the first place")
    func singleTileIsNotAnArrangement() {
        let host = "probe-host-\(UUID().uuidString)"
        MosaicArrangementStore.save([MosaicChoice(source: .display(1))], hostID: host)
        #expect(MosaicArrangementStore.load(hostID: host).isEmpty)
    }
}
