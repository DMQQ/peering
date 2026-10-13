import RemoteCore
import Testing

@testable import MacCastKit

@Suite struct FileDownloadValidationTests {
    private let chunk = FileDownloadLimits.chunkBytes
    private var chunkSize: Int64 { Int64(chunk) }

    private func started() -> FileDownloadWindow {
        var window = FileDownloadWindow()
        _ = window.first()
        return window
    }

    @Test func theFirstPieceIsAcceptedAndAsksForMore() throws {
        var window = started()
        let next = try window.accept(offset: 0, count: chunk, totalBytes: chunkSize * 3, freeDiskBytes: nil).get()
        #expect(next == [chunkSize, chunkSize * 2])
    }

    @Test func aNegativeOffsetIsRejected() {
        var window = started()
        #expect(window.accept(offset: -1, count: 10, totalBytes: 100, freeDiskBytes: nil) == .failure(.unexpectedData))
    }

    @Test func anOffsetThatWasNeverAskedForIsRejected() {
        var window = started()
        #expect(window.accept(offset: 5, count: 10, totalBytes: 100, freeDiskBytes: nil) == .failure(.unexpectedData))
    }

    @Test func aPieceAnsweredTwiceIsCountedOnce() throws {
        var window = started()
        _ = try window.accept(offset: 0, count: chunk, totalBytes: chunkSize * 3, freeDiskBytes: nil).get()
        let again = window.accept(offset: 0, count: chunk, totalBytes: chunkSize * 3, freeDiskBytes: nil)
        #expect(again == .failure(.unexpectedData))
        #expect(window.receivedBytes == chunkSize)
    }

    @Test func aPieceRunningPastTheEndIsRejected() {
        var window = started()
        #expect(window.accept(offset: 0, count: 50, totalBytes: 40, freeDiskBytes: nil) == .failure(.unexpectedData))
    }

    @Test func aSizeThatChangesMidwayIsRejected() throws {
        var window = started()
        _ = try window.accept(offset: 0, count: chunk, totalBytes: chunkSize * 3, freeDiskBytes: nil).get()
        let changed = window.accept(offset: chunkSize, count: chunk, totalBytes: chunkSize * 4, freeDiskBytes: nil)
        #expect(changed == .failure(.unexpectedData))
    }

    @Test func aTotalOverTheLimitIsRejected() {
        var window = started()
        let over = FileDownloadLimits.maximumBytes + 1
        #expect(window.accept(offset: 0, count: 10, totalBytes: over, freeDiskBytes: nil) == .failure(.tooLarge))
        #expect(window.accept(offset: 0, count: 10, totalBytes: -5, freeDiskBytes: nil) == .failure(.tooLarge))
    }

    @Test func aTotalBiggerThanTheFreeSpaceIsRejected() {
        var window = started()
        #expect(window.accept(offset: 0, count: 10, totalBytes: 1000, freeDiskBytes: 999) == .failure(.noRoomOnDisk))
        #expect(window.accept(offset: 0, count: 10, totalBytes: 1000, freeDiskBytes: 1000) == .success([]))
    }

    @Test func anEmptyFileCompletesOnItsFirstAnswer() throws {
        var window = started()
        _ = try window.accept(offset: 0, count: 0, totalBytes: 0, freeDiskBytes: nil).get()
        #expect(window.isComplete)
    }

    @Test func everyPieceInOrderOrNotCompletesTheFileOnce() throws {
        var window = started()
        let total = chunkSize * 2
        var pending = try window.accept(offset: 0, count: chunk, totalBytes: total, freeDiskBytes: nil).get()
        #expect(pending == [chunkSize])
        pending = try window.accept(offset: chunkSize, count: chunk, totalBytes: total, freeDiskBytes: nil).get()
        #expect(pending.isEmpty)
        #expect(window.isComplete)
    }

    @Test func theStallTimeoutIsThirtySeconds() {
        #expect(FileDownloadLimits.stallSeconds == 30)
    }
}
