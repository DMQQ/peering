import Foundation
import Network
import Testing

@testable import RemoteCore

extension ClientPairingTests {
    /// What the app's reconnect ladder stands on: a real session against a scripted Mac, dropped,
    /// ended and brought back.
    ///
    /// Nested so the parent's `.serialized` covers the Keychain keys these mint.
    @Suite("Connecting and reconnecting")
    struct Reconnect {
        private let hostID = "paired-mac"

        /// A Mac this device has paired with, a session for it, and everything torn down after.
        private func withPairedMac(
            _ body: (ScriptedMac, ClientSession, SessionLog, SelfSignedIdentity) async throws -> Void
        ) async throws {
            let pins = TestPins()
            defer { pins.destroy() }

            try await withTestEnds { client, macIdentity in
                #expect(
                    pins.store.record(hostID: hostID, publicKey: macIdentity.publicKeyBytes),
                    "the pin could not be stored"
                )
                let mac = try ScriptedMac(identity: macIdentity)
                await mac.start()
                defer { mac.stop() }

                let log = SessionLog()
                let session = ClientSession(
                    identity: client,
                    clientID: "phone-1",
                    clientName: "Test iPhone",
                    pins: pins.store,
                    onEvent: { log.record($0) }
                )
                defer { session.disconnect() }

                try await body(mac, session, log, macIdentity)
            }
        }

        private func target(_ mac: ScriptedMac) throws -> ClientSession.Target {
            guard let port = NWEndpoint.Port(rawValue: mac.port) else {
                throw TestSetupError("\(mac.port) is not a usable TCP port")
            }
            return .discovered(DiscoveredHost(
                id: hostID,
                name: "Scripted Mac",
                endpoint: .hostPort(host: "127.0.0.1", port: port),
                protocolVersion: ProtocolInfo.version,
                interfaceCount: 1
            ))
        }

        /// Dials, answers the handshake, and takes the video socket a ready session opens, so the
        /// next connection the Mac accepts belongs to the next dial.
        @discardableResult
        private func bringUp(
            _ mac: ScriptedMac,
            _ session: ClientSession,
            _ log: SessionLog
        ) async throws -> (control: MacLink, hello: ClientHello) {
            let readyBefore = log.phases.filter { $0 == .ready }.count
            let attempt = Task { [target = try target(mac)] in await session.connect(to: target, timeout: 10) }
            let control = try #require(await mac.nextConnection(), "the client never connected")
            let hello = try await greet(control, serverID: hostID, alreadyPaired: true)
            await attempt.value
            let ready = await log.wait { $0.phases.filter { $0 == .ready }.count > readyBefore }
            try #require(ready, "the session did not reach ready: \(log.phases)")

            let video = try #require(await mac.nextConnection(), "a ready session opened no video socket")
            _ = try await video.expect(.connectionRole)
            return (control, hello)
        }

        /// The next frame of `kind`, skipping the pings a ready session sends every second.
        private func nextFrame(_ kind: MessageKind, on link: MacLink, within seconds: TimeInterval = 5) async -> Frame? {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                guard let frame = await link.next(within: deadline.timeIntervalSinceNow) else { return nil }
                if frame.kind == kind { return frame }
            }
            return nil
        }

        /// The phases emitted since the `n`th `.connecting`, counting from one.
        private func phases(sinceConnecting n: Int, in log: SessionLog) -> [ClientSession.Phase] {
            var seen = 0
            return Array(log.phases.drop { phase in
                if phase == .connecting { seen += 1 }
                return seen < n
            })
        }

        @Test func aMacThatHangsUpFailsTheSessionWithTheNetworksReason() async throws {
            try await withPairedMac { mac, session, log, _ in
                let (control, _) = try await bringUp(mac, session, log)
                control.hangUp()

                let failed = await log.wait { $0.failure != nil }
                try #require(failed, "the Mac hung up and the session never noticed: \(log.phases)")
                let message = try #require(failurePhase(session))
                #expect(transportSentences.contains(message), "not a network sentence: \(message)")
                #expect(!session.isReady)
            }
        }

        /// The ladder dials again on whatever it holds, so a failed session has to be one that can.
        @Test func aFailedSessionConnectsAgain() async throws {
            try await withPairedMac { mac, session, log, _ in
                let (first, _) = try await bringUp(mac, session, log)
                first.hangUp()
                try #require(await log.wait { $0.failure != nil })

                try await bringUp(mac, session, log)
                #expect(session.phase == .ready)
                #expect(phases(sinceConnecting: 2, in: log).allSatisfy { !$0.isFailed })
            }
        }

        @Test func aDeliberateDisconnectIsNotAFailure() async throws {
            try await withPairedMac { mac, session, log, _ in
                try await bringUp(mac, session, log)
                session.disconnect()

                // Long enough for the sockets' own closes to arrive after the call returned.
                try await Task.sleep(for: .milliseconds(500))
                #expect(session.phase == .disconnected)
                #expect(log.failure == nil, "a deliberate end was reported as a failure: \(log.phases)")
            }
        }

        /// **The old socket's close is not news about the new one.** A disconnect cancels the
        /// socket, and the cancellation is reported later, from the network's queue. A dial made
        /// straight after is already under way by then, and must not hear it.
        @Test func aLateCloseFromTheOldSocketDoesNotReachTheNextDial() async throws {
            try await withPairedMac { mac, session, log, _ in
                try await bringUp(mac, session, log)
                session.disconnect()
                try await bringUp(mac, session, log)

                try await Task.sleep(for: .milliseconds(500))
                let since = phases(sinceConnecting: 2, in: log)
                #expect(session.phase == .ready)
                #expect(
                    !since.contains(.disconnected),
                    "the second dial was told it had disconnected: \(since)"
                )
            }
        }

        /// Two dials on one session leave one handshake, not two racing. Before the handshake has
        /// started the later dial takes over and the earlier one ends without a word.
        @Test func aSecondDialLeavesOneHandshake() async throws {
            try await withPairedMac { mac, session, log, _ in
                let target = try target(mac)
                let first = Task { await session.connect(to: target, timeout: 10) }
                try #require(await log.wait { $0.phases.contains(.connecting) })
                let second = Task { await session.connect(to: target, timeout: 10) }

                var greeted = 0
                while let link = await mac.nextConnection(within: 3) {
                    guard (try? await link.expect(.connectionRole, within: 2)) != nil else { continue }
                    let frame = try await link.expect(.clientHello)
                    _ = try MessageCodec.decode(ClientHello.self, from: frame.payload)
                    link.sendHello(serverID: hostID, alreadyPaired: true)
                    greeted += 1
                    if greeted == 1 { break }
                }
                await first.value
                await second.value

                #expect(greeted == 1)
                #expect(await log.wait { $0.isReady }, "neither dial reached ready: \(log.phases)")
                #expect(log.failure == nil || log.failure == ClientSession.Failure.busy.errorDescription)
                #expect(session.phase == .ready)
                // Whatever arrives next is the ready session's video socket, never a second control.
                if let extra = await mac.nextConnection(within: 1) {
                    let role = try? await extra.expect(.connectionRole, within: 1)
                    #expect(role?.payload != Data([ConnectionRole.control.rawValue]))
                }
            }
        }

        /// What the app asks as it comes back to the front: is the Mac still there?
        @Test func aMacThatStopsAnsweringFailsWhenAsked() async throws {
            try await withPairedMac { mac, session, log, _ in
                try await bringUp(mac, session, log)
                session.verifyStillAnswering()

                // The grace is at most 1.5 seconds.
                let failed = await log.wait(within: 3) { $0.failure != nil }
                #expect(failed, "a Mac that answered nothing was still called ready")
                #expect(log.failure?.hasPrefix("The Mac stopped answering") == true)
            }
        }

        @Test func aMacThatAnswersIsLeftAlone() async throws {
            try await withPairedMac { mac, session, log, _ in
                let (control, _) = try await bringUp(mac, session, log)
                session.verifyStillAnswering()

                let ping = try #require(await nextFrame(.ping, on: control), "no ping was sent")
                control.send(Frame(kind: .pong, payload: ping.payload))

                try await Task.sleep(for: .seconds(2))
                #expect(log.failure == nil, "a Mac that answered was failed: \(log.phases)")
                #expect(session.phase == .ready)
            }
        }

        /// A dial back to a Mac this device knows asks for the picture it was showing, so the Mac
        /// can start on it rather than on a display and then switch.
        @Test func aReconnectAsksForWhatWasOnScreen() async throws {
            try await withPairedMac { mac, session, log, _ in
                session.resumeSource = .window(42)
                let (first, hello) = try await bringUp(mac, session, log)
                #expect(hello.resumeSource == .window(42))

                first.hangUp()
                try #require(await log.wait { $0.failure != nil })
                session.resumeSource = .display(7)
                let (_, again) = try await bringUp(mac, session, log)
                #expect(again.resumeSource == .display(7))
            }
        }

        /// Input typed after a reconnect goes to the Mac that is there now.
        @Test func commandsAfterAReconnectReachTheNewConnection() async throws {
            try await withPairedMac { mac, session, log, _ in
                let (first, _) = try await bringUp(mac, session, log)
                first.hangUp()
                try #require(await log.wait { $0.failure != nil })

                let (control, _) = try await bringUp(mac, session, log)
                let key = RemoteCommand.keyDown(keyCode: 9, modifiers: [.command])
                session.send(key)

                let frame = try #require(await nextFrame(.command, on: control), "the command never arrived")
                #expect(try MessageCodec.decode(RemoteCommand.self, from: frame.payload) == key)
            }
        }
    }
}

private extension ClientSession.Phase {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
