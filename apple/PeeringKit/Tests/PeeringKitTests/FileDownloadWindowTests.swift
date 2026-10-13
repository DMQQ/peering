import RemoteCore
import Testing

@testable import PeeringKit

@Suite struct FileDownloadWindowTests {
    private let chunk = Int64(FileDownloadLimits.chunkBytes)

    @Test func theFirstPieceIsAskedForBlind() {
        var window = FileDownloadWindow()
        #expect(window.first() == 0)
        #expect(window.inFlight == 1)
        #expect(window.fraction == nil)
    }

    @Test func aBigFileKeepsTheWindowFull() {
        var window = FileDownloadWindow()
        _ = window.first()
        let next = window.received(count: Int(chunk), totalBytes: chunk * 100)
        #expect(next.count == FileDownloadLimits.window)
        #expect(next.first == chunk)
        #expect(window.inFlight == FileDownloadLimits.window)
    }

    @Test func eachArrivalAsksForExactlyOneMoreOnceTheWindowIsFull() {
        var window = FileDownloadWindow()
        _ = window.first()
        _ = window.received(count: Int(chunk), totalBytes: chunk * 100)
        let next = window.received(count: Int(chunk), totalBytes: chunk * 100)
        #expect(next.count == 1)
        #expect(next.first == chunk * Int64(FileDownloadLimits.window + 1))
    }

    @Test func aSmallFileAsksForNothingMore() {
        var window = FileDownloadWindow()
        _ = window.first()
        let next = window.received(count: 100, totalBytes: 100)
        #expect(next.isEmpty)
        #expect(window.isComplete)
        #expect(window.fraction == 1)
    }

    @Test func itNeverAsksPastTheEnd() {
        var window = FileDownloadWindow()
        _ = window.first()
        let next = window.received(count: Int(chunk), totalBytes: chunk * 3 - 10)
        #expect(next == [chunk, chunk * 2])
    }

    @Test func itIsCompleteOnlyWhenEveryByteArrived() {
        var window = FileDownloadWindow()
        _ = window.first()
        _ = window.received(count: Int(chunk), totalBytes: chunk * 2)
        #expect(!window.isComplete)
        _ = window.received(count: Int(chunk), totalBytes: chunk * 2)
        #expect(window.isComplete)
    }
}
