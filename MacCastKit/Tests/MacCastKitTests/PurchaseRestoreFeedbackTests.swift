//
//  PurchaseRestoreFeedbackTests.swift
//  MacCastKitTests
//

import XCTest
@testable import MacCastKit

final class PurchaseRestoreFeedbackTests: XCTestCase {
    func testNothingOnTheAppleAccountIsSaidOutLoud() {
        XCTAssertEqual(
            PurchaseRestoreFeedback.message(didRestore: false, error: nil),
            "No purchases to restore on this Apple Account."
        )
    }

    func testTheAppStoresFailureIsShownInsteadOfTheNothingFoundMessage() {
        XCTAssertEqual(
            PurchaseRestoreFeedback.message(
                didRestore: false,
                error: "The App Store is unavailable."
            ),
            "The App Store is unavailable."
        )
    }
}
