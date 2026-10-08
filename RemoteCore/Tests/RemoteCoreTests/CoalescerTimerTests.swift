//
//  CoalescerTimerTests.swift
//  RemoteCoreTests
//

import XCTest
@testable import RemoteCore

/// The timer was once started on connect and stopped only at teardown, waking the CPU sixty times a second for an empty queue. It now exists only while something waits.
final class CoalescerTimerTests: XCTestCase {

    /// Primed, because the first command is always due (`lastFlush` starts at zero on a monotonic clock): an unprimed test would exercise the leading edge, not the trailing one.
    private func makeCoalescer() -> (CommandCoalescer, () -> [RemoteCommand]) {
        let sent = LockedBox<[RemoteCommand]>([])
        let coalescer = CommandCoalescer(interval: 60) { command in
            sent.mutate { $0.append(command) }
        }
        coalescer.enqueue(.mouseDown(button: .left))
        coalescer.flush()
        return (coalescer, { sent.value })
    }

    func testStartingOnAnEmptyQueueArmsNothing() {
        let (coalescer, _) = makeCoalescer()
        coalescer.start()
        XCTAssertFalse(coalescer.isArmed)
    }

    func testACommandLeftWaitingArmsTheTimer() {
        let (coalescer, _) = makeCoalescer()
        // Within the interval and mergeable, so it stays queued.
        coalescer.enqueue(.joystickMove(dx: 1, dy: 1))
        XCTAssertTrue(coalescer.isArmed)
    }

    func testDrainingTheQueueDisarmsTheTimer() {
        let (coalescer, _) = makeCoalescer()
        coalescer.enqueue(.joystickMove(dx: 1, dy: 1))
        XCTAssertTrue(coalescer.isArmed)
        coalescer.flush()
        XCTAssertFalse(coalescer.isArmed)
    }

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
