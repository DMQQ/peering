//
//  TourCalloutTests.swift
//  MacCastKitTests
//

import XCTest
@testable import MacCastKit

/// Card placement: a card over its control still draws fine but hides what the person was asked to look at.
final class TourCalloutTests: XCTestCase {

    private let phone = CGSize(width: 393, height: 760)
    private let card = CGSize(width: 340, height: 130)

    /// Under the control first, always: a card above it lands on the line being read.
    func testTheCardGoesUnderTheControlWhenThereIsRoom() {
        let hole = CGRect(x: 40, y: 200, width: 300, height: 90)
        let placement = TourCallout.placement(hole: hole, cardSize: card, in: phone)

        XCTAssertEqual(placement.caretEdge, .below)
        XCTAssertGreaterThan(placement.frame.minY, hole.maxY, "The card should clear the control.")
        XCTAssertLessThanOrEqual(placement.frame.maxY, phone.height - 16)
    }

    /// A control at the foot of the screen puts the card above it; there is no room under the dock.
    func testTheCardGoesOverTheControlWhenThereIsNoRoomUnder() {
        let hole = CGRect(x: 20, y: 640, width: 353, height: 96)
        let placement = TourCallout.placement(hole: hole, cardSize: card, in: phone)

        XCTAssertEqual(placement.caretEdge, .above)
        XCTAssertLessThan(placement.frame.maxY, hole.minY, "The card should clear the control.")
        XCTAssertGreaterThanOrEqual(placement.frame.minY, 16)
    }

    func testTheCaretPointsAtTheControl() {
        let hole = CGRect(x: 300, y: 200, width: 80, height: 44)
        let placement = TourCallout.placement(hole: hole, cardSize: card, in: phone)

        XCTAssertLessThanOrEqual(placement.caretX, placement.frame.maxX - 22)
        XCTAssertGreaterThanOrEqual(placement.caretX, placement.frame.minX + 22)
        XCTAssertLessThanOrEqual(placement.frame.maxX, phone.width - 16)
    }

    func testTheCardStaysOnTheScreen() {
        for x in stride(from: CGFloat(0), through: phone.width, by: 40) {
            for y in stride(from: CGFloat(0), through: phone.height, by: 90) {
                let hole = CGRect(x: x, y: y, width: 60, height: 40)
                let placement = TourCallout.placement(hole: hole, cardSize: card, in: phone)
                XCTAssertGreaterThanOrEqual(placement.frame.minX, 16, "hole at \(hole)")
                XCTAssertGreaterThanOrEqual(placement.frame.minY, 16, "hole at \(hole)")
                XCTAssertLessThanOrEqual(placement.frame.maxX, phone.width - 16, "hole at \(hole)")
                XCTAssertLessThanOrEqual(
                    placement.frame.maxY,
                    phone.height - 16,
                    "hole at \(hole)"
                )
            }
        }
    }

    /// The ordinary cases do not cover the control: the property the type exists for.
    func testTheCardDoesNotCoverTheControl() {
        for y in stride(from: CGFloat(0), through: phone.height - 44, by: 44) {
            let hole = CGRect(x: 20, y: y, width: 353, height: 44)
            let placement = TourCallout.placement(hole: hole, cardSize: card, in: phone)
            // A control taller than the room on either side cannot be satisfied; no step points at one.
            XCTAssertFalse(
                placement.frame.intersects(hole),
                "The card covers a control at y \(y)."
            )
        }
    }

    /// A card that fits on neither side takes the end the control is not at, keeping most of the control visible.
    func testACardThatFitsNowhereGoesToTheFarEnd() {
        let tall = CGSize(width: 340, height: 650)
        let lowHole = CGRect(x: 40, y: 620, width: 300, height: 60)
        let highHole = CGRect(x: 40, y: 40, width: 300, height: 60)

        let under = TourCallout.placement(hole: lowHole, cardSize: tall, in: phone)
        XCTAssertEqual(under.caretEdge, .above)
        XCTAssertEqual(under.frame.minY, 16, "The card should be at the far end from the control.")

        let over = TourCallout.placement(hole: highHole, cardSize: tall, in: phone)
        XCTAssertEqual(over.caretEdge, .below)
        XCTAssertEqual(over.frame.maxY, phone.height - 16)
    }

    /// The card is never wider than the screen; the cap stops it becoming a bar in landscape.
    func testTheCardFitsEveryScreen() {
        XCTAssertEqual(TourCallout.cardWidth(in: CGSize(width: 320, height: 568)), 288)
        XCTAssertEqual(TourCallout.cardWidth(in: CGSize(width: 430, height: 932)), 340)
        XCTAssertEqual(TourCallout.cardWidth(in: CGSize(width: 932, height: 430)), 340)
        XCTAssertEqual(TourCallout.cardWidth(in: CGSize(width: 20, height: 568)), 0)
    }
}
