//
//  TourCalloutTests.swift
//  MacCastKitTests
//

import XCTest
@testable import MacCastKit

/// Where a tour's card lands, tested where it can be run.
///
/// **This is the one part of the tips that can be wrong without looking wrong.** A card placed over
/// the control it is describing still draws, still says the right sentence and still has a working
/// Next button; what it does is hide the thing the person was asked to look at, and the only way to
/// find that out from the app is to reach the screen, in the right orientation, on a phone whose
/// safe areas put the control where it goes wrong. Four numbers in, four numbers out, and every
/// arrangement of them can be tried here.
final class TourCalloutTests: XCTestCase {

    /// A portrait phone, and a control in the middle of it.
    private let phone = CGSize(width: 393, height: 760)
    private let card = CGSize(width: 340, height: 130)

    /// The ordinary case: the card goes under the control.
    ///
    /// Under first, always. The control is what the person is looking at, and a card that arrives
    /// above it lands on the line they are reading.
    func testTheCardGoesUnderTheControlWhenThereIsRoom() {
        let hole = CGRect(x: 40, y: 200, width: 300, height: 90)
        let placement = TourCallout.placement(hole: hole, cardSize: card, in: phone)

        XCTAssertEqual(placement.caretEdge, .below)
        XCTAssertGreaterThan(placement.frame.minY, hole.maxY, "The card should clear the control.")
        XCTAssertLessThanOrEqual(placement.frame.maxY, phone.height - 16)
    }

    /// A control at the foot of the screen puts the card above it.
    ///
    /// The dock is the case: it stands at the bottom edge, and there is never room under it.
    func testTheCardGoesOverTheControlWhenThereIsNoRoomUnder() {
        let hole = CGRect(x: 20, y: 640, width: 353, height: 96)
        let placement = TourCallout.placement(hole: hole, cardSize: card, in: phone)

        XCTAssertEqual(placement.caretEdge, .above)
        XCTAssertLessThan(placement.frame.maxY, hole.minY, "The card should clear the control.")
        XCTAssertGreaterThanOrEqual(placement.frame.minY, 16)
    }

    /// The caret points at the control, wherever the card has been pushed to.
    func testTheCaretPointsAtTheControl() {
        let hole = CGRect(x: 300, y: 200, width: 80, height: 44)
        let placement = TourCallout.placement(hole: hole, cardSize: card, in: phone)

        // The card is clamped in from the right edge, and the caret comes with it as far as it can
        // while still sitting on the card's own edge.
        XCTAssertLessThanOrEqual(placement.caretX, placement.frame.maxX - 22)
        XCTAssertGreaterThanOrEqual(placement.caretX, placement.frame.minX + 22)
        XCTAssertLessThanOrEqual(placement.frame.maxX, phone.width - 16)
    }

    /// The card never runs off the screen, whichever end of it the control is at.
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

    /// The ordinary cases do not cover the control.
    ///
    /// Stated as its own test rather than left to the two above, because this is the property the
    /// whole type exists for: everything else here is about where the card looks best, and this is
    /// about whether the person can see what they were asked to look at.
    func testTheCardDoesNotCoverTheControl() {
        for y in stride(from: CGFloat(0), through: phone.height - 44, by: 44) {
            let hole = CGRect(x: 20, y: y, width: 353, height: 44)
            let placement = TourCallout.placement(hole: hole, cardSize: card, in: phone)
            // A control taller than the room left on either side of it is the one arrangement that
            // cannot be satisfied, and nothing in the app is one: every step points at a card, a
            // row or a bar, all of them shorter than half a phone.
            XCTAssertFalse(
                placement.frame.intersects(hole),
                "The card covers a control at y \(y)."
            )
        }
    }

    /// A card that fits on neither side goes to the far end of the screen.
    ///
    /// The keyboard, a landscape phone, a very long sentence: there is no arrangement that keeps it
    /// clear, so the question becomes which half of the screen it takes. The end the control is
    /// *not* at, so that as much of the control as possible stays visible. The card here is taller
    /// than either side of the control can hold, which is the only way to reach this branch.
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

    /// The card is never wider than the screen it is on, whatever that screen is.
    ///
    /// The copy is fixed and the phones are not: the same sentence has to fit a small phone in
    /// portrait and a whole landscape screen, where the cap is what stops it becoming a bar.
    func testTheCardFitsEveryScreen() {
        XCTAssertEqual(TourCallout.cardWidth(in: CGSize(width: 320, height: 568)), 288)
        XCTAssertEqual(TourCallout.cardWidth(in: CGSize(width: 430, height: 932)), 340)
        XCTAssertEqual(TourCallout.cardWidth(in: CGSize(width: 932, height: 430)), 340)
        XCTAssertEqual(TourCallout.cardWidth(in: CGSize(width: 20, height: 568)), 0)
    }
}
