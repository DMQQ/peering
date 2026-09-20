//
//  CoalescerTimerTests.swift
//  RemoteCoreTests
//

import XCTest
@testable import RemoteCore

/// When the command coalescer's timer is allowed to run.
///
/// **A rule about a wake-up that does not happen**, which is why it needs a test rather than a
/// reading. The timer used to be started when a connection came up and stopped only when the
/// session was destroyed, so a Mac left open on a desk had the CPU woken sixty times a second for
/// a queue that was empty. Nothing about that is visible: the session works, the picture is fine,
/// and the cost is a battery chart that is a little worse than it should be. With several sessions
/// open at once it is that cost multiplied by the number of Macs, none of them being used.
///
/// So the timer exists while there is something waiting and not otherwise, and these are the three
/// moments that decide it.
final class CoalescerTimerTests: XCTestCase {

    /// A coalescer with a long interval, and its clock already started.
    ///
    /// **Primed, because the first command through is always due.** `lastFlush` begins at zero and
    /// the clock is monotonic, so the first interval measured is the whole uptime of the machine —
    /// every command goes out on its leading edge until one of them has been sent. A test that
    /// enqueued straight into a fresh coalescer would therefore be testing the leading edge while
    /// claiming to test the trailing one.
    private func makeCoalescer() -> (CommandCoalescer, () -> [RemoteCommand]) {
        let sent = LockedBox<[RemoteCommand]>([])
        let coalescer = CommandCoalescer(interval: 60) { command in
            sent.mutate { $0.append(command) }
        }
        coalescer.enqueue(.mouseDown(button: .left))
        coalescer.flush()
        return (coalescer, { sent.value })
    }

    /// **The one the fix is about.** A connection coming up arms nothing, because there is nothing
    /// to send, and an idle session must not be waking the CPU at all.
    func testStartingOnAnEmptyQueueArmsNothing() {
        let (coalescer, _) = makeCoalescer()
        coalescer.start()
        XCTAssertFalse(coalescer.isArmed)
    }

    /// A command the leading edge did not send leaves something waiting, and waiting is what the
    /// timer is for.
    func testACommandLeftWaitingArmsTheTimer() {
        let (coalescer, _) = makeCoalescer()
        // A relative delta within the interval: too soon to send, and mergeable, so it stays
        // queued rather than going out on the leading edge.
        coalescer.enqueue(.joystickMove(dx: 1, dy: 1))
        XCTAssertTrue(coalescer.isArmed)
    }

    /// And once the queue has been drained there is nothing left to wake up for.
    func testDrainingTheQueueDisarmsTheTimer() {
        let (coalescer, _) = makeCoalescer()
        coalescer.enqueue(.joystickMove(dx: 1, dy: 1))
        XCTAssertTrue(coalescer.isArmed)
        coalescer.flush()
        XCTAssertFalse(coalescer.isArmed)
    }

    /// A command that may not be delayed goes out immediately and arms nothing, because a timer
    /// started for a queue that is already empty is the whole bug in miniature.
    func testACommandSentImmediatelyArmsNothing() {
        let (coalescer, sent) = makeCoalescer()
        let before = sent().count
        coalescer.enqueue(.mouseDown(button: .left))
        XCTAssertFalse(coalescer.isArmed)
        // Counted as a difference: the coalescer is primed, so the absolute count includes a
        // command this test did not send.
        XCTAssertEqual(sent().count - before, 1)
    }
}

/// A value several queues touch, for a test that has no actor to lean on.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&stored)
    }
}
