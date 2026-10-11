import Testing

@testable import RemoteCore

@Suite("Video delivery record")
struct VideoDeliveryRecordTests {
    @Test("the first picture is timed from the moment the session was ready")
    func firstPictureIsMeasuredFromReady() {
        var record = VideoDeliveryRecord(readyAt: 100)
        record.notePicture(at: 100.4)
        record.notePicture(at: 103)

        #expect(record.firstPictureMilliseconds == 400)
    }

    @Test("a session that never got a picture has no first-picture time")
    func noPictureMeansNoTime() {
        let record = VideoDeliveryRecord(readyAt: 100)

        #expect(record.firstPictureMilliseconds == nil)
    }

    @Test("a fallback stays recorded after the picture returns to the datagram lane")
    func fallbackIsSticky() {
        var record = VideoDeliveryRecord(readyAt: 0)
        record.note(transport: .control)
        record.note(transport: .primary)

        #expect(record.fellBack)
        #expect(record.transport == .primary)
    }

    @Test("a session that stayed on the datagram lane did not fall back")
    func noFallbackByDefault() {
        let record = VideoDeliveryRecord(readyAt: 0)

        #expect(!record.fellBack)
        #expect(record.transport == .primary)
    }
}
