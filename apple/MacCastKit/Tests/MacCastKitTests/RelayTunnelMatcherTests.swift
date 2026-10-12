import Foundation
import Testing

@testable import MacCastKit

struct RelayTunnelMatcherTests {
    private let start = Date(timeIntervalSince1970: 2_000)

    @Test func aConnectionFromTheNetworkNeverMatchesATunnel() {
        var matcher = RelayTunnelMatcher()
        let tunnel = UUID()
        _ = matcher.add(tunnel, now: start)

        #expect(matcher.claim(loopbackPort: nil, knownPorts: [:], now: start) == nil)
        #expect(matcher.pendingIDs == [tunnel])
    }

    @Test func aLoopbackConnectionMatchesTheTunnelWithItsSourcePort() {
        var matcher = RelayTunnelMatcher()
        let first = UUID()
        let second = UUID()
        _ = matcher.add(first, now: start)
        _ = matcher.add(second, now: start)

        let claimed = matcher.claim(loopbackPort: 50_002, knownPorts: [first: 50_001, second: 50_002], now: start)
        #expect(claimed == second)
        #expect(matcher.pendingIDs == [first])
    }

    @Test func aTunnelThatHasNotLearnedItsPortIsMatchedInArrivalOrder() {
        var matcher = RelayTunnelMatcher()
        let first = UUID()
        let second = UUID()
        _ = matcher.add(first, now: start)
        _ = matcher.add(second, now: start)

        #expect(matcher.claim(loopbackPort: 50_009, knownPorts: [:], now: start) == first)
    }

    @Test func aTunnelWithAnotherKnownPortIsNotTakenForTheConnection() {
        var matcher = RelayTunnelMatcher()
        let tunnel = UUID()
        _ = matcher.add(tunnel, now: start)

        #expect(matcher.claim(loopbackPort: 50_009, knownPorts: [tunnel: 50_001], now: start) == nil)
        #expect(matcher.pendingIDs == [tunnel])
    }

    @Test func aTunnelPastItsLifetimeIsNotMatchedAndIsReturnedForClosing() {
        var matcher = RelayTunnelMatcher()
        let tunnel = UUID()
        _ = matcher.add(tunnel, now: start)
        let late = start.addingTimeInterval(11)

        #expect(matcher.claim(loopbackPort: 50_001, knownPorts: [:], now: late) == nil)
        #expect(matcher.expire(now: late) == [tunnel])
        #expect(matcher.pendingIDs.isEmpty)
    }

    @Test func pendingTunnelsAreCapped() {
        var matcher = RelayTunnelMatcher()
        for _ in 0..<RelayTunnelMatcher.maximumPending {
            #expect(matcher.add(UUID(), now: start) == true)
        }
        #expect(matcher.add(UUID(), now: start) == false)
    }

    @Test func aClosedTunnelLeavesThePendingList() {
        var matcher = RelayTunnelMatcher()
        let tunnel = UUID()
        _ = matcher.add(tunnel, now: start)
        matcher.remove(tunnel)
        #expect(matcher.pendingIDs.isEmpty)
    }
}
