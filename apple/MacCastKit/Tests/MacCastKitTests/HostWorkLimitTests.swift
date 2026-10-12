import Foundation
import Testing
@testable import MacCastKit

struct ConcurrencyLimiterTests {
    @Test func slotsRunOutAndComeBackWhenReleased() {
        let limiter = ConcurrencyLimiter(limit: 2)
        #expect(limiter.tryAcquire())
        #expect(limiter.tryAcquire())
        #expect(!limiter.tryAcquire())
        limiter.release()
        #expect(limiter.tryAcquire())
        #expect(limiter.activeCount == 2)
    }
}

struct CachedProbeTests {
    private final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []
        func add(_ value: Int) { lock.withLock { values.append(value) } }
        var all: [Int] { lock.withLock { values } }
    }

    @Test func callersDuringAProbeShareItsAnswer() {
        let probe = CachedProbe<Int>(lifetime: 60)
        let received = Received()
        guard case .start = probe.request(at: 0, reply: { received.add($0) }) else {
            Issue.record("the first caller should run the probe")
            return
        }
        guard case .wait = probe.request(at: 1, reply: { received.add($0) }) else {
            Issue.record("the second caller should wait")
            return
        }
        probe.finish(7, at: 2)
        #expect(received.all == [7, 7])
    }

    @Test func theAnswerIsReusedForSixtySecondsAndThenProbedAgain() {
        let probe = CachedProbe<Int>(lifetime: 60)
        _ = probe.request(at: 0, reply: { _ in })
        probe.finish(3, at: 0)
        guard case .answer(let value) = probe.request(at: 59, reply: { _ in }) else {
            Issue.record("a fresh answer should be reused")
            return
        }
        #expect(value == 3)
        guard case .start = probe.request(at: 61, reply: { _ in }) else {
            Issue.record("a stale answer should start a new probe")
            return
        }
    }
}

struct UploadWritePolicyTests {
    @Test func onlyTransfersSilentForTheLimitAreIdle() {
        let idle = UploadWritePolicy.idle(["old": 0.0, "new": 80.0], now: 100, limit: 90)
        #expect(idle == ["old"])
    }

    @Test func stagingFilesAreRecognisedByTheirNameAlone() {
        #expect(UploadWritePolicy.isStagingFile(named: ".photo.png.peering-5F0C6B7E-3C1D-4B53-9D0E-0A5F6C1B2D34.part"))
        #expect(!UploadWritePolicy.isStagingFile(named: "photo.png.peering-5F0C6B7E-3C1D-4B53-9D0E-0A5F6C1B2D34.part"))
        #expect(!UploadWritePolicy.isStagingFile(named: ".notes.part"))
        #expect(!UploadWritePolicy.isStagingFile(named: ".a.peering-not-a-uuid.part"))
    }

    @Test func queuedBytesAreRefusedPastTheLimitAndReleasedAfterTheWrite() {
        var budget = QueuedByteBudget(limit: 100)
        let result1 = budget.reserve(60)
        #expect(result1)
        let result2 = budget.reserve(41)
        #expect(!result2)
        budget.release(60)
        let result3 = budget.reserve(100)
        #expect(result3)
    }
}

struct BoundedOutputTests {
    @Test func outputPastTheCapIsCutAndFlagged() {
        var output = BoundedOutput(limit: 5)
        let result4 = output.append(Data([1, 2, 3]))
        #expect(result4)
        let result5 = output.append(Data([4, 5, 6, 7]))
        #expect(!result5)
        #expect(output.data == Data([1, 2, 3, 4, 5]))
        #expect(output.exceeded)
    }

    @Test func aWaitStatusBecomesAnExitCodeOrASignalOffset() {
        #expect(ProcessWaitStatus.exitCode(fromWaitStatus: 0) == 0)
        #expect(ProcessWaitStatus.exitCode(fromWaitStatus: 3 << 8) == 3)
        #expect(ProcessWaitStatus.exitCode(fromWaitStatus: 9) == 137)
    }
}

struct ArchiveBudgetTests {
    @Test func theDiskMustHoldTheCapPlusTheReserve() {
        let cap: Int64 = 1_000
        #expect(!ArchiveBudget.hasRoom(freeBytes: cap + ArchiveBudget.reserveBytes - 1, cap: cap))
        #expect(ArchiveBudget.hasRoom(freeBytes: cap + ArchiveBudget.reserveBytes, cap: cap))
    }

    @Test func aZipIsStoppedOnlyOncePastTheCap() {
        #expect(!ArchiveBudget.mustStop(archiveBytes: 1_000, cap: 1_000))
        #expect(ArchiveBudget.mustStop(archiveBytes: 1_001, cap: 1_000))
    }
}

struct SettingsFileReadTests {
    @Test func aMissingFileIsAbsence() {
        #expect(SettingsFileRead.isAbsence(CocoaError(.fileReadNoSuchFile)))
        #expect(SettingsFileRead.isAbsence(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))))
    }

    @Test func anExistingFileThatCannotBeReadIsNotAbsence() {
        #expect(!SettingsFileRead.isAbsence(CocoaError(.fileReadNoPermission)))
        #expect(!SettingsFileRead.isAbsence(NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))))
    }
}
