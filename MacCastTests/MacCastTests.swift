//
//  MacCastTests.swift
//  MacCastTests
//
//  Created by Damian Derlecki on 13/09/2026.
//

import CoreGraphics
import MacCastKit
import RemoteCore
import UIKit
import XCTest
@testable import MacCast

/// The two tests that need a real UIKit view, and the whole of what is left here.
///
/// **Everything else that was in this file now lives in `MacCastKitTests`**, where it runs. See
/// that file's header for why: Xcode 27 cannot execute this target's test action at all, because
/// for a test action it builds every package product as a separate dynamic framework and the Crypto
/// product's target never runs a link step, so X509, RemoteCore and the app fail to link in a
/// cascade. Nothing in the app can fix that, so the policy moved to where it could be checked and
/// this is what genuinely cannot follow it: a `GestureSurfaceView` has to lay out before it will
/// report the bounds two of these measure against, and there is no honest way to do that without a
/// view.
///
/// These will run the day the test action works again. Until then they compile, and they are the
/// only things here that do not run somewhere else.
@MainActor
final class MacCastTests: XCTestCase {

    func testPortraitGestureSurfaceUsesItsOwnBoundsForCentreTap() async throws {
        let normalized = try await normalizedCentreReportedByGestureSurface(
            size: CGSize(width: 430, height: 932)
        )

        XCTAssertEqual(normalized.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(normalized.y, 0.5, accuracy: 0.001)
    }

    func testLandscapeGestureSurfaceUsesItsOwnBoundsForCentreTap() async throws {
        let normalized = try await normalizedCentreReportedByGestureSurface(
            size: CGSize(width: 932, height: 430)
        )

        XCTAssertEqual(normalized.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(normalized.y, 0.5, accuracy: 0.001)
    }

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
}
