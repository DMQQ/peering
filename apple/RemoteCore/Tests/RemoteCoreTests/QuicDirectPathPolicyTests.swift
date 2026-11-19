import Foundation
import Testing

@testable import RemoteCore

struct QuicDirectPathPolicyTests {
    private let relay = QuicAddress(host: "65.21.127.107", port: 3479)!
    private let peer = QuicAddress(host: "203.0.113.7", port: 50_000)!
    private let start = ContinuousClock.Instant.now

    @Test("the phone probes the address the relay named, and moves onto it once it validates")
    func theDialerProbesThenMoves() {
        var policy = QuicDirectPathPolicy(role: .dialer, relay: relay, now: start)
        #expect(policy.tick(now: start, silence: nil) == [.askRelay])
        #expect(policy.peerAddressAnswered(peer) == [.report(.probing(peer: "203.0.113.7:50000"))])
        #expect(policy.tick(now: start, silence: nil) == [.knock(peer), .probe(peer)])
        let moved = policy.handle(.validated(local: relay, peer: peer))
        #expect(moved == [.migrate(to: peer), .report(.open(peer: "203.0.113.7:50000")), .onPath(.direct)])
        #expect(policy.direct == peer)
    }

    @Test("the relay's own path validating is not a direct path")
    func theRelayPathIsNotDirect() {
        var policy = QuicDirectPathPolicy(role: .dialer, relay: relay, now: start)
        #expect(policy.handle(.validated(local: relay, peer: relay)).isEmpty)
        #expect(policy.direct == nil)
    }

    @Test("a direct path that goes silent falls back to the relay")
    func silenceFallsBack() {
        var policy = QuicDirectPathPolicy(role: .dialer, relay: relay, now: start)
        _ = policy.handle(.validated(local: relay, peer: peer))
        #expect(policy.tick(now: start, silence: .milliseconds(500)).isEmpty)
        let actions = policy.tick(now: start, silence: .seconds(3))
        #expect(actions.starts(with: [.migrate(to: relay), .onPath(.relay)]))
        #expect(policy.direct == nil)
    }

    @Test("a network change moves back to the relay at once and forgets the old address")
    func aNetworkChangeFallsBack() {
        var policy = QuicDirectPathPolicy(role: .dialer, relay: relay, now: start)
        _ = policy.peerAddressAnswered(peer)
        _ = policy.handle(.validated(local: relay, peer: peer))
        #expect(policy.networkChanged(now: start) == [.migrate(to: relay), .onPath(.relay), .report(.notTried)])
        #expect(policy.tick(now: start, silence: nil) == [.askRelay])
    }

    @Test("the Mac only knocks, and follows the phone onto the direct path and back")
    func theListenerFollows() {
        var policy = QuicDirectPathPolicy(role: .listener, relay: relay, now: start)
        _ = policy.peerAddressAnswered(peer)
        #expect(policy.tick(now: start, silence: nil) == [.askRelay, .knock(peer)])
        #expect(policy.handle(.peerMigrated(local: relay, peer: peer)) == [.report(.open(peer: "203.0.113.7:50000")), .onPath(.direct)])
        #expect(policy.handle(.peerMigrated(local: relay, peer: relay)) == [.onPath(.relay)])
    }

    @Test("the relay route is refreshed while the session runs direct, so there is somewhere to fall back to")
    func theRelayRouteStaysWarm() {
        var policy = QuicDirectPathPolicy(role: .dialer, relay: relay, now: start)
        _ = policy.handle(.validated(local: relay, peer: peer))
        #expect(policy.tick(now: start + .seconds(11), silence: .zero) == [.refreshRelayBinding])
    }

    @Test("an attempt that never opens is called once its time is up")
    func theVerdictComesOnce() {
        var policy = QuicDirectPathPolicy(role: .dialer, relay: relay, now: start)
        let late = start + .seconds(9)
        #expect(policy.tick(now: late, silence: nil).contains(.verdictDue))
        #expect(!policy.tick(now: late, silence: nil).contains(.verdictDue))
    }

    private let lan = QuicAddress(host: "192.168.1.20", port: 50_001)!

    @Test("on the Mac's own network the phone probes the Mac's LAN address too, and a working one is a LAN path")
    func theLANAddressIsProbed() {
        var policy = QuicDirectPathPolicy(role: .dialer, relay: relay, now: start)
        policy.announcedAddresses([lan])
        _ = policy.peerAddressAnswered(peer)
        #expect(policy.tick(now: start, silence: nil) == [.askRelay, .knock(peer), .probe(lan), .probe(peer)])
        #expect(policy.handle(.validated(local: relay, peer: lan)) == [.migrate(to: lan), .report(.open(peer: "192.168.1.20:50001")), .onPath(.lan)])
    }

    @Test("a session on a public direct path moves to the LAN when that validates, and not the other way")
    func theLANBeatsAPublicPath() {
        var policy = QuicDirectPathPolicy(role: .dialer, relay: relay, now: start)
        policy.announcedAddresses([lan])
        _ = policy.handle(.validated(local: relay, peer: peer))
        #expect(policy.tick(now: start, silence: .zero) == [.probe(lan)])
        #expect(policy.handle(.validated(local: relay, peer: lan)).first == .migrate(to: lan))
        #expect(policy.handle(.validated(local: relay, peer: peer)).isEmpty)
        #expect(policy.tick(now: start, silence: .zero).isEmpty)
    }

    @Test("an announced address that is public is not taken for the LAN")
    func onlyPrivateAddressesAreAnnouncedLAN() {
        var policy = QuicDirectPathPolicy(role: .dialer, relay: relay, now: start)
        policy.announcedAddresses([peer])
        #expect(policy.tick(now: start, silence: nil) == [.askRelay])
    }

    @Test("a session carried over from the LAN probes the relay first, then moves onto it")
    func aCarriedSessionMovesOntoTheRelay() {
        var policy = QuicDirectPathPolicy(role: .dialer, relay: relay, startsOnRelay: false, now: start)
        #expect(policy.tick(now: start, silence: nil) == [.probe(relay)])
        #expect(policy.handle(.validated(local: relay, peer: relay)) == [.migrate(to: relay), .onPath(.relay)])
        #expect(policy.tick(now: start, silence: nil) == [.askRelay])
    }

    @Test("leaving the LAN asks for a new relay route instead of trusting one that may have lapsed")
    func leavingTheLANRenewsTheRelay() {
        var policy = QuicDirectPathPolicy(role: .dialer, relay: relay, now: start)
        policy.announcedAddresses([lan])
        _ = policy.handle(.validated(local: relay, peer: lan))
        #expect(policy.networkChanged(now: start) == [.renewRelay, .report(.notTried)])
    }

    @Test("the relay route is not kept alive while the session is on the LAN, so relay time is not spent there")
    func noRelayRefreshOnTheLAN() {
        var policy = QuicDirectPathPolicy(role: .dialer, relay: relay, now: start)
        policy.announcedAddresses([lan])
        _ = policy.handle(.validated(local: relay, peer: lan))
        #expect(policy.tick(now: start + .seconds(11), silence: .zero).isEmpty)
    }
}
