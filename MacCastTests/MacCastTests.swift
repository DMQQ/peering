//
//  MacCastTests.swift
//  MacCastTests
//
//  Created by Damian Derlecki on 13/09/2026.
//

import RemoteCore
import XCTest
@testable import MacCast

final class MacCastTests: XCTestCase {

    // Gesture locations and the bounds used to normalize them must come from the same UIKit
    // view. RemoteScreen used to mix this full-screen coordinate space with its safe-area-sized
    // SwiftUI root, shifting the Mac cursor much farther in portrait than in landscape.
    @MainActor
    func testPortraitGestureSurfaceUsesItsOwnBoundsForCentreTap() async throws {
        let normalized = try await normalizedCentreReportedByGestureSurface(
            size: CGSize(width: 430, height: 932)
        )

        XCTAssertEqual(normalized.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(normalized.y, 0.5, accuracy: 0.001)
    }

    @MainActor
    func testLandscapeGestureSurfaceUsesItsOwnBoundsForCentreTap() async throws {
        let normalized = try await normalizedCentreReportedByGestureSurface(
            size: CGSize(width: 932, height: 430)
        )

        XCTAssertEqual(normalized.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(normalized.y, 0.5, accuracy: 0.001)
    }

    // MARK: - Interaction mode

    // The mode is the whole safety story of the in-session screen: drag & zoom is only worth
    // having if a finger in it cannot reach the Mac. These pin the routing rather than the
    // recognisers, because a `UIPanGestureRecognizer` cannot be driven from a unit test — and
    // "nothing was sent" is exactly the claim that has to keep holding.

    func testViewAndScrollTouchesReachTheMac() {
        let mode = InteractionMode.control

        XCTAssertFalse(mode.oneFingerDragPansCanvas)
        XCTAssertFalse(mode.twoFingerDragPansCanvas)
        XCTAssertFalse(mode.pinchZoomsCanvas)
        XCTAssertTrue(mode.tapsReachTheMac)
    }

    func testDragAndZoomTouchesNeverReachTheMac() {
        let mode = InteractionMode.navigate

        XCTAssertTrue(mode.oneFingerDragPansCanvas)
        XCTAssertTrue(mode.twoFingerDragPansCanvas)
        XCTAssertTrue(mode.pinchZoomsCanvas)
        XCTAssertFalse(mode.tapsReachTheMac)
    }

    /// A finger either drives the Mac or moves the picture, never both. Stated as an invariant
    /// over every case so a third mode added later cannot quietly be both at once.
    func testNoModeBothPansAndClicks() {
        for mode in InteractionMode.allCases {
            XCTAssertNotEqual(mode.oneFingerDragPansCanvas, mode.tapsReachTheMac)
        }
    }

    func testTogglingInteractionModeIsItsOwnInverse() {
        for mode in InteractionMode.allCases {
            XCTAssertEqual(mode.toggled.toggled, mode)
            XCTAssertNotEqual(mode.toggled, mode)
        }
    }

    /// The switch is stored as its raw value, so that string is a persistence format and not an
    /// implementation detail. The default has to be the behaviour that existed before the switch
    /// did, or an upgrade silently changes how the screen responds to a finger.
    func testInteractionModeRoundTripsThroughItsStoredValue() {
        for mode in InteractionMode.allCases {
            XCTAssertEqual(InteractionMode(rawValue: mode.rawValue), mode)
        }

        XCTAssertEqual(InteractionMode(rawValue: "control"), .control)
        XCTAssertNil(InteractionMode(rawValue: "dragging"))
    }

    /// The rail button is captioned with the mode's own name and icon, so two modes that agreed
    /// on either would leave a button that cannot say which way it is pointing.
    func testEachModeIsDistinguishableOnItsButton() {
        XCTAssertEqual(Set(InteractionMode.allCases.map(\.label)).count, InteractionMode.allCases.count)
        XCTAssertEqual(Set(InteractionMode.allCases.map(\.symbol)).count, InteractionMode.allCases.count)
    }

    @MainActor
    private func normalizedCentreReportedByGestureSurface(size: CGSize) async throws -> NormalizedPoint {
        let sizeReported = expectation(description: "gesture surface reported its UIKit bounds")
        var reportedSize: CGSize?
        let surface = GestureSurfaceView(frame: CGRect(origin: .zero, size: size))
        surface.handlers = .init(
            onTouchDown: { _ in },
            onTouchMove: { _ in },
            onTouchUp: { _ in },
            onSecondaryClick: { _ in },
            onScroll: { _ in },
            onZoom: { _, _ in },
            onPanCanvas: { _ in },
            onSizeChange: {
                reportedSize = $0
                sizeReported.fulfill()
            }
        )

        surface.setNeedsLayout()
        surface.layoutIfNeeded()
        await fulfillment(of: [sizeReported], timeout: 1)

        let bounds = try XCTUnwrap(reportedSize)
        return try XCTUnwrap(CanvasGeometry.normalized(
            point: CGPoint(x: bounds.width / 2, y: bounds.height / 2),
            bounds: bounds,
            pixelSize: CGSize(width: 1800, height: 1168),
            zoom: 1,
            pan: .zero
        ))
    }

    // MARK: - Session awareness

    // A banner is a claim the user cannot check against anything, made at a moment they are
    // not looking. These pin what gets claimed — and mostly what does not, because only three
    // transitions out of the whole state machine are worth an interruption, and the events
    // that are not are the ones a reconnect loop would turn into a stream of banners.

    func testAReadySessionThatFailsNotifies() {
        let notification = SessionAwareness.notification(
            from: .ready,
            to: .failed("The Mac stopped responding."),
            hostName: "Studio",
            deliberate: false
        )

        XCTAssertNotNil(notification)
    }

    func testAReadySessionThatDropsNotifies() {
        let notification = SessionAwareness.notification(
            from: .ready,
            to: .disconnected,
            hostName: "Studio",
            deliberate: false
        )

        XCTAssertNotNil(notification)
    }

    /// Six digits are worth one banner, not one per phase the session passed through on its
    /// way to showing them: both routes into the prompt produce the same notification, so a
    /// session that arrives there twice replaces its own banner instead of stacking a second
    /// one behind it.
    func testThePairingCodeNotifiesExactlyOnce() {
        let afterConnecting = SessionAwareness.notification(
            from: .connecting,
            to: .confirming(code: "419302"),
            hostName: "Studio",
            deliberate: false
        )
        let afterHandshaking = SessionAwareness.notification(
            from: .handshaking,
            to: .confirming(code: "419302"),
            hostName: "Studio",
            deliberate: false
        )

        XCTAssertNotNil(afterConnecting)
        XCTAssertEqual(afterConnecting, afterHandshaking)
    }

    /// The model sets `.disconnected` itself and the session then reports one of its own, so
    /// the second delivery — which arrives with the phase already equal to the one it carries
    /// — must not read as the transition it is not.
    func testARepeatedPhaseIsNotATransition() {
        XCTAssertNil(SessionAwareness.notification(
            from: .ready, to: .ready, hostName: "Studio", deliberate: false
        ))
        XCTAssertNil(SessionAwareness.notification(
            from: .disconnected, to: .disconnected, hostName: "Studio", deliberate: false
        ))
    }

    func testConnectingNotifiesNobody() {
        XCTAssertNil(SessionAwareness.notification(
            from: .idle, to: .connecting, hostName: "Studio", deliberate: false
        ))
        XCTAssertNil(SessionAwareness.notification(
            from: .connecting, to: .handshaking, hostName: "Studio", deliberate: false
        ))
    }

    /// The user tapping Disconnect and the Mac vanishing are the same phase, and a banner
    /// telling someone what they just did is the notification equivalent of an echo.
    func testAUserEndedConnectionIsNotAConnectionLost() {
        XCTAssertNil(SessionAwareness.notification(
            from: .ready, to: .disconnected, hostName: "Studio", deliberate: true
        ))
    }

}
