//
//  ObservationForwardingTests.swift
//  MacCastKitTests
//

import Foundation
import Observation
import XCTest
@testable import MacCastKit

/// The one assumption the per-Mac split rests on, written down where it can be checked.
///
/// **`SessionModel` no longer stores most of what its screens read.** `phase`, `terminals`,
/// `videoStatus` and thirty others are per-Mac facts that moved onto `MacSession`, and the model
/// exposes each of them as a computed property that reads through to the active session. That is
/// invisible to the compiler and invisible to a build: if Observation did not record a read of a
/// *nested* observable through a computed property, every screen in the app would draw once and
/// then never update again, and nothing would fail until somebody watched a session for ten
/// seconds.
///
/// So the shape is reproduced here in miniature — a container holding children, a computed
/// forwarder to one of them — and the question is asked directly: does a write to the child
/// reach an observer that only ever read through the container? The app target cannot run its
/// own tests under this toolchain (`xcodebuild test` fails to link the package products, see
/// `AGENTS.md`), so this is the only place the question can be answered by a build.
final class ObservationForwardingTests: XCTestCase {

    @Observable
    @MainActor
    final class Child {
        let id = UUID()
        var phase: String = "idle"
    }

    @Observable
    @MainActor
    final class Container {
        var children: [Child] = []
        var activeChildID: UUID?

        /// The shape of ``SessionModel/activeSession`` and of every forwarder beside it.
        var activeChild: Child? {
            guard let activeChildID else { return nil }
            return children.first { $0.id == activeChildID }
        }

        var phase: String {
            get { activeChild?.phase ?? "idle" }
            set { activeChild?.phase = newValue }
        }
    }

    @MainActor
    private func makeContainer() -> (Container, Child) {
        let container = Container()
        let child = Child()
        container.children = [child]
        container.activeChildID = child.id
        return (container, child)
    }

    /// A write to the child must invalidate a view that only read `container.phase`.
    @MainActor
    func testAWriteToTheChildIsObservedThroughTheContainersForwarder() {
        let (container, child) = makeContainer()

        let observed = expectation(description: "the container's forwarder fired")
        withObservationTracking {
            _ = container.phase
        } onChange: {
            observed.fulfill()
        }

        child.phase = "ready"
        wait(for: [observed], timeout: 1)
    }

    /// And a write *through* the forwarder must land on the child, which is the half that makes
    /// the app's screens able to go on setting state the way they always did.
    @MainActor
    func testAWriteThroughTheForwarderLandsOnTheChild() {
        let (container, child) = makeContainer()
        container.phase = "ready"
        XCTAssertEqual(child.phase, "ready")
    }

    /// Swapping the active child is itself observable, or a screen reading a forwarded property
    /// would keep drawing the Mac that used to be selected.
    @MainActor
    func testChangingTheActiveChildIsObserved() {
        let (container, _) = makeContainer()
        let other = Child()
        other.phase = "ready"
        container.children.append(other)

        let observed = expectation(description: "the selection change fired")
        withObservationTracking {
            _ = container.phase
        } onChange: {
            observed.fulfill()
        }

        container.activeChildID = other.id
        wait(for: [observed], timeout: 1)
    }

    /// With nothing selected the forwarder answers a resting value rather than trapping, which
    /// is what the app does before its first connection.
    @MainActor
    func testAnEmptyContainerReadsItsRestingValue() {
        XCTAssertEqual(Container().phase, "idle")
    }
}
