import Foundation
import Testing

@testable import PeeringKit

@Suite("What a peering link may do")
struct URLCommandPolicyTests {
    private func parse(_ text: String) -> URLCommand? {
        URL(string: text).flatMap(URLCommandPolicy.parse)
    }

    @Test func readsTheLinksTheWidgetsSend() {
        #expect(parse("peering://connect") == .connect(hostID: nil))
        #expect(parse("peering://connect?id=abc") == .connect(hostID: "abc"))
        #expect(parse("peering://disconnect") == .disconnect)
        #expect(parse("peering://end-shells") == .endShells)
    }

    @Test func aChatLinkNeedsAChatID() {
        let chat = UUID()
        #expect(parse("peering://chat?id=\(chat.uuidString)&host=h") == .chat(chatID: chat, hostID: "h"))
        #expect(parse("peering://chat") == nil)
        #expect(parse("peering://chat?id=nope") == nil)
    }

    @Test func ignoresOtherSchemesAndHosts() {
        #expect(parse("https://example.com/disconnect") == nil)
        #expect(parse("peering://format-disk") == nil)
    }

    @Test func endingALiveSessionAsksFirst() {
        #expect(decide(.disconnect, session: true) == .confirm)
        #expect(decide(.endShells, shells: true) == .confirm)
    }

    @Test func endingNothingJustRuns() {
        #expect(decide(.disconnect) == .run)
        #expect(decide(.endShells) == .run)
    }

    @Test func connectingNeverAsks() {
        #expect(decide(.connect(hostID: nil), session: true, shells: true) == .run)
    }

    @Test func everythingWaitsBehindTheLock() {
        for command in [URLCommand.connect(hostID: nil), .chat(chatID: UUID(), hostID: nil), .pairingCode(URL(string: "peering://pair?code=123456")!), .disconnect, .endShells] {
            #expect(decide(command, locked: true, session: true, shells: true) == .holdUntilUnlock)
        }
    }

    private func decide(
        _ command: URLCommand,
        locked: Bool = false,
        session: Bool = false,
        shells: Bool = false
    ) -> URLCommandPolicy.Decision {
        URLCommandPolicy.decide(command, isLocked: locked, hasLiveSession: session, hasLiveShells: shells)
    }
}
