import Foundation
import Testing
@testable import PeeringKit

struct HostEventCodesTests {
    @Test func sessionRefIsEightLowercaseHexAndDiffersBetweenCalls() {
        let first = SessionRef.make()
        #expect(SessionRef.sanitized(first) == first)
        #expect(first != SessionRef.make())
    }

    @Test func sessionRefFromAHelloIsDroppedUnlessItIsExactlyEightHexCharacters() {
        #expect(SessionRef.sanitized("0a1b2c3d") == "0a1b2c3d")
        #expect(SessionRef.sanitized("0A1B2C3D") == nil)
        #expect(SessionRef.sanitized("0a1b2c3") == nil)
        #expect(SessionRef.sanitized("my-laptop") == nil)
        #expect(SessionRef.sanitized(nil) == nil)
    }

    @Test func clientPlatformReadsAnAbsentFieldAsIosAndStrangersAsUnknown() {
        #expect(HostEventCodes.clientPlatformName(nil) == "ios")
        #expect(HostEventCodes.clientPlatformName("android") == "android")
        #expect(HostEventCodes.clientPlatformName("Pixel 9 of Ann") == "unknown")
    }

    @Test func endPropertiesCarryOnlyClosedValuesAndBuckets() {
        let properties = HostEventCodes.endProperties(
            reason: .silence, durationSeconds: 125, route: .relay, clientPlatform: "android",
            bytesSent: 50_000_000, droppedFrames: 12, encoderRestarts: 99, sessionRef: "0a1b2c3d"
        )
        #expect(properties["end_reason"] as? String == "silence")
        #expect(properties["duration_s"] as? Int == 125)
        #expect(properties["route"] as? String == "relay")
        #expect(properties["client_platform"] as? String == "android")
        #expect(properties["bytes_sent_bucket"] as? String == "<100MB")
        #expect(properties["dropped_frames_bucket"] as? String == "<100")
        #expect(properties["encoder_restarts"] as? Int == 20)
        #expect(properties["session_ref"] as? String == "0a1b2c3d")
    }

    @Test func endPropertiesOmitASessionRefThatIsNotWellFormed() {
        let properties = HostEventCodes.endProperties(
            reason: .clientClosed, durationSeconds: -3, route: .lan, clientPlatform: nil,
            bytesSent: 0, droppedFrames: 0, encoderRestarts: 0, sessionRef: "not a ref"
        )
        #expect(properties["session_ref"] as? String == nil)
        #expect(properties["duration_s"] as? Int == 0)
    }

    @Test func aFailureLoopSendsOneEventPerCodePerMinuteAndCountsTheRest() {
        var limiter = HostErrorLimiter()
        let start = ContinuousClock.now
        #expect(limiter.admit(.captureFailed, at: start) == 1)
        #expect(limiter.admit(.captureFailed, at: start.addingTimeInterval(1)) == nil)
        #expect(limiter.admit(.captureFailed, at: start.addingTimeInterval(30)) == nil)
        #expect(limiter.admit(.captureFailed, at: start.addingTimeInterval(61)) == 3)
        #expect(limiter.admit(.captureFailed, at: start.addingTimeInterval(62)) == nil)
    }

    @Test func eachCodeHasItsOwnWindow() {
        var limiter = HostErrorLimiter()
        let start = ContinuousClock.now
        #expect(limiter.admit(.captureFailed, at: start) == 1)
        #expect(limiter.admit(.encoderFailed, at: start) == 1)
    }
}
