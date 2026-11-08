import CoreGraphics
import Foundation
import Testing
@testable import PeeringKit

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

@Suite("Joystick response")
struct JoystickResponseTests {
    private let screen = CGSize(width: 1000, height: 600)

    private func travel(_ deflection: CGFloat, seconds: TimeInterval = 1) -> CGSize {
        PointerTravel.travel(offset: CGSize(width: deflection * 50, height: 0), radius: 50, pointSize: screen, interval: seconds)
    }

    @Test("full deflection crosses 0.8 screen widths in a second")
    func fullDeflection() {
        #expect(abs(travel(1).width - 800) < 0.001)
    }

    @Test("a half push moves well under half as fast as a full one")
    func halfPush() {
        #expect(travel(0.5).width < 300)
    }

    @Test("a centred stick does not move")
    func centred() {
        #expect(travel(0) == .zero)
    }

    @Test("travel keeps the direction of the push")
    func direction() {
        let step = PointerTravel.travel(offset: CGSize(width: -30, height: 40), radius: 50, pointSize: screen, interval: 0.1)
        #expect(step.width < 0 && step.height > 0)
    }
}
