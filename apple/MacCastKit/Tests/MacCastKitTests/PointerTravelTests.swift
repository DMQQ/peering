import CoreGraphics
import Testing
@testable import MacCastKit

struct PointerTravelTests {
    @Test("a MacBook display, already in points, is left alone")
    func pointsStay() {
        #expect(PointerTravel.pointSize(forPicture: CGSize(width: 1512, height: 982)) == CGSize(width: 1512, height: 982))
    }

    @Test("a large panel reported in pixels is halved")
    func pixelsHalve() {
        #expect(PointerTravel.pointSize(forPicture: CGSize(width: 5120, height: 2880)) == CGSize(width: 2560, height: 1440))
    }
}
