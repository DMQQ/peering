//
//  ObservationForwardingTests.swift
//  MacCastKitTests
//

import Foundation
import Observation
import XCTest
@testable import MacCastKit

/// SessionModel forwards per-Mac state through computed properties to the active session. If Observation did not
/// track nested reads through them, screens would draw once and never update. The app target cannot run tests (see AGENTS.md).
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

    @MainActor
    func testAWriteThroughTheForwarderLandsOnTheChild() {
        let (container, child) = makeContainer()
        container.phase = "ready"
        XCTAssertEqual(child.phase, "ready")
    }

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

    @MainActor
    func testAnEmptyContainerReadsItsRestingValue() {
        XCTAssertEqual(Container().phase, "idle")
    }
}
