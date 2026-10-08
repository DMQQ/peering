import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import Network
import RemoteCore

/// A minimal headless client: connect, handshake, pair, and report what happened.
///
/// This exists so phases 1–3 are provable without any iOS UI. It deliberately uses the
/// same `RemoteCore` types the real client will, so a handshake that works here is a
/// handshake that works there — the only thing it stubs out is the user tapping "the
/// digits match", which `--accept` supplies.
@main
struct Probe {
    struct ProbeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func main() async {
        do {
            try await run()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            FileHandle.standardError.write(Data("probe failed: \(message)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        var options = Options()
        try options.parse(CommandLine.arguments.dropFirst())

        log("client identity \(options.clientID) as “\(options.clientName)”")

        // Discovery runs first when asked for, and can be the whole job. Browsing is
        // otherwise never exercised — a direct connection to 127.0.0.1 proves the listener
        // works and says nothing at all about whether the service advertises, whether the
        // TXT record arrives intact, or whether the client's Info.plist will let it browse
        // at all. Those are exactly the failures that are silent on iOS.
        var target: DiscoveredHost?
        if options.browseOnly || options.find != nil {
            let found = try await browse(seconds: options.browseSeconds)
            guard !found.isEmpty else {
                throw ProbeError(message: """
                    no MacCast hosts found in \(Int(options.browseSeconds))s.
                    Check that the host is running and that this process may browse \
                    \(ProtocolInfo.bonjourServiceType).
                    """)
            }

            if let query = options.find {
                guard let match = found.first(where: { $0.matches(query) }) else {
                    throw ProbeError(message: """
                        nothing matches “\(query)”. Found:
                        \(found.map { "  \($0.name)  [\($0.id)]" }.joined(separator: "\n"))
                        """)
                }
                target = match
            }

            if options.browseOnly {
                log("done browsing")
                return
            }
        }

        // A tag of its own, separate from the real client's. The probe is rebuilt constantly
        // and code signing decides which process may use a keychain key, so sharing the
        // client tag would put the two in each other's way for no benefit.
        let keyTag = Data("pl.dmq.maccast.probe.identity".utf8)
        if options.resetIdentity {
            do {
                try SelfSignedIdentity.destroy(role: .client, keyTag: keyTag)
                log("destroyed the previous probe identity")
            } catch {
                log("could NOT destroy the previous identity: \(error)")
            }
        }

        let identity = try SelfSignedIdentity.loadOrCreate(
            role: .client,
            commonName: options.clientName,
            keyTag: keyTag
        )
        log("client key \(identity.publicKeyBytes.hexString)")

        if options.videoOnly {
            // No control connection at all, so the host has no authorized session for this
            // client key and must refuse the video connection it is about to be offered.
            try await checkVideoConnection(
                identity: identity,
                options: options,
                expectAccepted: false
            )
            return
        }

        let observed = TLSConfig.ObservedKey()
        let channel = FrameChannel()

        if let target {
            log("connecting to “\(target.name)” at \(target.endpoint.debugDescription)")
            try await channel.connect(
                endpoint: target.endpoint,
                clientIdentity: identity,
                pinnedServerKey: options.pinnedKey,
                observed: observed,
                timeout: options.timeout
            )
        } else {
            try await channel.connect(
                host: options.host,
                port: options.port,
                clientIdentity: identity,
                pinnedServerKey: options.pinnedKey,
                observed: observed,
                timeout: options.timeout
            )
        }

        // 1. Declare the role. Both channels share one listener; this is what tells the
        //    host which one it just accepted.
        channel.send(Frame(kind: .connectionRole, payload: Data([ConnectionRole.control.rawValue])))

        // 2. Say who we are.
        let hello = ClientHello(
            clientID: options.clientID,
            clientName: options.clientName,
            protocolVersion: ProtocolInfo.version,
            wantsPairing: options.pinnedKey == nil,
            // Declared so the host will stream agent events here. Without it every event of a
            // chat is dropped by the host's own restraint, and the probe waits on a session
            // that is working perfectly.
            supportsAgentChat: true
        )
        channel.send(Frame(kind: .clientHello, payload: try MessageCodec.encode(hello)))

        // 3. The host's reply. The host name here is authoritative — Bonjour is only a
        //    hint about where to find it.
        let serverHelloFrame = try await channel.next()
        guard serverHelloFrame.kind == .serverHello else {
            throw ProbeError(message: "expected serverHello, got \(serverHelloFrame.kind)")
        }
        let serverHello = try MessageCodec.decode(ServerHello.self, from: serverHelloFrame.payload)
        log("server “\(serverHello.hostName)” id \(serverHello.serverID) v\(serverHello.protocolVersion)")
        log("negotiated \(channel.negotiatedTLSVersion)")

        guard let serverKey = observed.value else {
            throw ProbeError(message: "TLS did not expose a server certificate — no pin to check")
        }
        log("server key \(serverKey.count) bytes")
        try verifyPin(options.pinnedKey, serverKey)

        if serverHello.alreadyPaired {
            log("already paired — handshake complete with no user interaction")
            try await postHandshake(channel, options: options, identity: identity)
            return
        }

        guard options.pinnedKey == nil else {
            throw ProbeError(message: "server does not recognise this pin; re-pair from the device")
        }

        // 4. SAS pairing, with the commitment exchange that makes it ungrindable.
        let paired = try await pair(
            channel: channel,
            clientID: options.clientID,
            serverHello: serverHello,
            serverKey: serverKey,
            accept: options.accept
        )

        // Declining is a legitimate outcome, not a failure. Pinging an abandoned session
        // would report the host's ensuing close as an error and bury the actual result.
        guard paired else {
            channel.cancel()
            return
        }

        try await postHandshake(channel, options: options, identity: identity)
    }

    // MARK: - Pairing

    /// Runs the SAS exchange. Returns whether the host ended up pinning this client, so the
    /// caller can stop rather than pinging a session it deliberately declined.
    @discardableResult
    static func pair(
        channel: FrameChannel,
        clientID: String,
        serverHello: ServerHello,
        serverKey: Data,
        accept: Bool
    ) async throws -> Bool {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let nonce = try randomBytes(32)
        let commitment = PairingSAS.commitment(
            ephemeralPublicKey: ephemeral.publicKey.x963Representation,
            nonce: nonce
        )

        // Commit first. Neither side reveals until both have committed, so the digits
        // cannot be steered after the fact.
        channel.send(Frame(kind: .pairCommit, payload: try MessageCodec.encode(PairingCommit(commitment: commitment))))

        let serverCommitFrame = try await channel.next()
        guard serverCommitFrame.kind == .pairCommit else {
            throw ProbeError(message: "expected pairCommit, got \(serverCommitFrame.kind)")
        }
        let serverCommit = try MessageCodec.decode(PairingCommit.self, from: serverCommitFrame.payload)

        channel.send(Frame(kind: .pairReveal, payload: try MessageCodec.encode(
            PairingReveal(ephemeralPublicKey: ephemeral.publicKey.x963Representation, nonce: nonce)
        )))

        let serverRevealFrame = try await channel.next()
        guard serverRevealFrame.kind == .pairReveal else {
            throw ProbeError(message: "expected pairReveal, got \(serverRevealFrame.kind)")
        }
        let serverReveal = try MessageCodec.decode(PairingReveal.self, from: serverRevealFrame.payload)

        guard PairingSAS.verify(
            commitment: serverCommit.commitment,
            ephemeralPublicKey: serverReveal.ephemeralPublicKey,
            nonce: serverReveal.nonce
        ) else {
            throw ProbeError(message: "the host's reveal did not match its commitment — this is a live attack")
        }

        let transcript = PairingTranscript(
            protocolVersion: ProtocolInfo.version,
            clientID: clientID,
            serverID: serverHello.serverID,
            clientEphemeralPublicKey: ephemeral.publicKey.x963Representation,
            serverEphemeralPublicKey: serverReveal.ephemeralPublicKey,
            clientNonce: nonce,
            serverNonce: serverReveal.nonce,
            serverIdentityPublicKey: serverKey
        )
        let code = PairingSAS.code(for: transcript)
        log("SAS code: \(code)  ← must match the host window")

        channel.send(Frame(kind: .pairConfirm, payload: try MessageCodec.encode(PairConfirm(accepted: accept))))
        guard accept else {
            log("sent rejection; pairing abandoned")
            return false
        }

        let resultFrame = try await channel.next()
        guard resultFrame.kind == .pairResult else {
            throw ProbeError(message: "expected pairResult, got \(resultFrame.kind)")
        }
        let result = try MessageCodec.decode(PairResult.self, from: resultFrame.payload)
        guard result.accepted else {
            throw ProbeError(message: "host refused the pairing: \(result.reason ?? "no reason given")")
        }
        log("pairing accepted — the host has pinned this client")
        return true
    }

    /// Set by `run()` before pairing; a static because the transcript needs it and there is
    /// exactly one connection per process.
    nonisolated(unsafe) static var options_clientID = "probe-client"

    // MARK: - Discovery

    /// Collects browse results for a fixed window.
    ///
    /// A fixed window rather than "return the first result", because the question during
    /// development is usually what *else* is on the network. A host that fails to appear is
    /// much easier to diagnose next to the list of what did.
    static func browse(seconds: TimeInterval) async throws -> [DiscoveredHost] {
        let browser = HostBrowser()
        let collector = HostCollector()
        browser.onEvent = { collector.offer($0) }
        browser.start()

        log("browsing for \(ProtocolInfo.bonjourServiceType) for \(Int(seconds))s…")
        try? await Task.sleep(for: .seconds(seconds))
        browser.stop()

        if let failure = collector.failure {
            throw ProbeError(message: "browse failed: \(failure)")
        }

        let hosts = collector.hosts
        if hosts.isEmpty {
            log("nothing advertised \(ProtocolInfo.bonjourServiceType)")
        }
        for host in hosts {
            let version = host.protocolVersion.map { "v\($0)" } ?? "version unknown"
            let extra = host.interfaceCount > 1 ? " · \(host.interfaceCount) interfaces" : ""
            log("found “\(host.name)” id \(host.id) · \(version)\(extra)")
        }
        return hosts
    }

    // MARK: - Input

    /// A single step of input, in the order the arguments were given.
    ///
    /// Order is the point: a test of keycode mode wants to type, press a key, then type
    /// again and see where the keystroke landed among the text. Storing one value per flag
    /// would silently keep only the last of each and quietly test something else.
    enum InputAction {
        case type(String)
        case key(UInt16, Modifiers)
        case space(SpaceDirection)
        case verifySpaces
        case flags(String)
    }

    /// Returns the active macOS Space ID. There is no public API for observing Spaces, so
    /// this verification-only probe resolves the same read-only WindowServer function used
    /// by diagnostic tools at runtime. Production code does not depend on it.
    static func activeSpaceID() throws -> UInt64 {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let handle = dlopen(path, RTLD_LAZY),
              let mainSymbol = dlsym(handle, "CGSMainConnectionID"),
              let activeSymbol = dlsym(handle, "CGSGetActiveSpace") else {
            throw ProbeError(message: "could not inspect the active macOS Space")
        }
        typealias MainConnection = @convention(c) () -> UInt32
        typealias GetActiveSpace = @convention(c) (UInt32) -> UInt64
        let mainConnection = unsafeBitCast(mainSymbol, to: MainConnection.self)
        let getActiveSpace = unsafeBitCast(activeSymbol, to: GetActiveSpace.self)
        return getActiveSpace(mainConnection())
    }

    static func verifySpaceSwitching(on channel: FrameChannel) async throws {
        let original = try activeSpaceID()
        for direction: SpaceDirection in [.right, .left] {
            try send(.switchSpace(direction: direction), on: channel)
            try await settle(channel)
            let deadline = ContinuousClock.now + .seconds(2)
            while ContinuousClock.now < deadline {
                let current = try activeSpaceID()
                if current != original {
                    log("SPACE SWITCH OK · \(direction.rawValue) moved \(original) → \(current)")
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        throw ProbeError(message: "switchSpace left/right left the active Space unchanged (\(original))")
    }

    /// Reports what the window server currently believes is held.
    ///
    /// This is how a stuck modifier is detected without a focused application in the loop.
    /// A GUI target would be the obvious check, but it is the wrong instrument: it only
    /// answers the question when focus happens to be right, and every earlier attempt to
    /// verify modifiers this way was confounded by whichever window was in front. The
    /// session's own modifier state is the actual quantity of interest — if a chord fails to
    /// release, it shows up here regardless of what has focus.
    static func reportFlags(_ label: String) {
        let state = CGEventSource.flagsState(.combinedSessionState)
        let held = describe(state)
        // The raw value is printed next to the names on purpose. This machine's flag state
        // carries bit 29 set at all times, including with nothing held — outside the named
        // modifier masks, but inside `maskDeviceIndependentFlagsMask`. Reporting only the
        // four names made that bit invisible here while it was still visible to every caller
        // comparing raw values, which is a gap between what this prints and what it means.
        log("""
            \(label): session modifiers = \(held.isEmpty ? "none" : held) \
            (raw 0x\(String(state.rawValue, radix: 16)))
            """)
    }

    /// The held modifiers, named, for a log line or an error.
    static func describe(_ flags: CGEventFlags) -> String {
        var held: [String] = []
        if flags.contains(.maskCommand) { held.append("cmd") }
        if flags.contains(.maskShift) { held.append("shift") }
        if flags.contains(.maskControl) { held.append("ctrl") }
        if flags.contains(.maskAlternate) { held.append("opt") }
        if flags.contains(.maskAlphaShift) { held.append("caps") }
        return held.joined(separator: "+")
    }

    /// The modifier bits a stuck chord would leave behind.
    ///
    /// Everything outside this mask is deliberately excluded from the hold-and-drop check.
    /// Comparing whole raw values compares state this probe never touched — the always-set
    /// bit 29 above is enough on its own to make an unfixed and a fixed host look identical,
    /// so the check would fail against both and mean nothing either way.
    static let modifierMask: CGEventFlags = [
        .maskCommand, .maskShift, .maskControl, .maskAlternate, .maskAlphaShift,
    ]

    /// Holds a key down and then drops the connection without ever releasing it, to check
    /// that the host cleans up after a client that dies mid-chord.
    ///
    /// **A clean shutdown cannot test this, which is why it needs its own mode.** Quitting
    /// properly sends the key-up, and the key-up is what releases the modifier — so a probe
    /// that exits normally would read "no modifiers held" whether or not the host does
    /// anything at teardown, and would pass against the unfixed host too. Reproducing the
    /// accident means sending a lone key-down and then cancelling the socket with nothing
    /// behind it, which is exactly what a dropped Wi-Fi connection looks like from here.
    ///
    /// The first `reportFlags` is what gives the second one meaning. On its own, "no
    /// modifiers are held after the drop" is also what a probe that failed to press
    /// anything would print, so the check is the pair: held before, released after. If the
    /// first reading says nothing is held, the whole run proves nothing and says so.
    static func holdAndDrop(_ channel: FrameChannel, code: UInt16) async throws {
        try send(.keyDown(keyCode: code, modifiers: []), on: channel)
        try await settle(channel)
        reportFlags("holding keycode \(code) (want it held)")

        let before = CGEventSource.flagsState(.combinedSessionState)
            .intersection(Self.modifierMask)
        guard before.rawValue != 0 else {
            throw ProbeError(message: """
                keycode \(code) did not take hold, so the drop below cannot show anything. \
                Either it is not a modifier keycode or the host is not injecting — check \
                Accessibility trust before reading anything into this run.
                """)
        }

        channel.cancel()
        log("dropped the control connection with keycode \(code) still down")

        // Long enough for the host to see the close, tear the session down and post the
        // release; short enough that it cannot be something else — nothing else on this
        // machine is going to release a modifier in the next second.
        try? await Task.sleep(for: .seconds(1))
        reportFlags("after the drop (want none)")

        let after = CGEventSource.flagsState(.combinedSessionState)
            .intersection(Self.modifierMask)
        let stillHeld = after.intersection(before)
        guard stillHeld.rawValue == 0 else {
            throw ProbeError(message: """
                the host left \(describe(stillHeld)) held after the client dropped — a Mac \
                in this state reads every later keystroke as a shortcut until a real key-up \
                arrives.
                """)
        }
        log("HOLD AND DROP OK · the host released what the dead client left held")
    }

    /// The button half of the same accident: press a mouse button, drop the connection, and
    /// check the host let go of it.
    ///
    /// It needs its own test because the stuck state is worse than a stuck modifier and a
    /// great deal harder to recognise. A Mac left holding the left button does not look
    /// broken — it looks like the next physical click "did not register", because that click
    /// was consumed as the *end* of a drag the user never started. Nothing on screen says a
    /// button is down, so the symptom gets attributed to whatever was clicked.
    ///
    /// `buttonState` is the read that makes this checkable, and it is the counterpart to
    /// `flagsState` above: it reports what the window server believes about a mouse button,
    /// independently of where the pointer is or what has focus.
    static func holdButtonAndDrop(_ channel: FrameChannel, button: MouseButton) async throws {
        try send(.mouseDown(button: button), on: channel)
        try await settle(channel)

        let before = CGEventSource.buttonState(.combinedSessionState, button: cgButton(button))
        log("holding the \(button) button (want it held): down = \(before)")
        guard before else {
            throw ProbeError(message: """
                the \(button) button did not register as pressed, so the drop below cannot \
                show anything — the host is not injecting mouse events.
                """)
        }

        channel.cancel()
        log("dropped the control connection with the \(button) button still down")

        try? await Task.sleep(for: .seconds(1))
        let after = CGEventSource.buttonState(.combinedSessionState, button: cgButton(button))
        log("after the drop (want not held): down = \(after)")
        guard !after else {
            throw ProbeError(message: """
                the host left the \(button) mouse button held after the client dropped. The \
                user's next physical click will be consumed as the end of a drag they never \
                started, and nothing on screen says why.
                """)
        }
        log("BUTTON HOLD AND DROP OK · the host released the button the dead client left down")
    }

    /// The `CGMouseButton` for a command's button. The raw values already line up: left 0,
    /// right 1, other 2.
    static func cgButton(_ button: MouseButton) -> CGMouseButton {
        CGMouseButton(rawValue: UInt32(button.rawValue)) ?? .left
    }

    /// Everything the probe does once the session is usable.
    /// Opens a connection that declares the video role and reports whether the host keeps it.
    ///
    /// **This tests a security property, not a feature.** A video connection carries no
    /// handshake of its own — no hello, no pairing, not even a client ID — so the host has
    /// nothing to authorize it with except the client key on its TLS certificate. And the
    /// host's TLS verify block accepts *any* self-signed chain by design, because
    /// authenticity here comes from pairing rather than a CA. So the rule under test is:
    ///
    /// - a client key that matches an authorized control session is accepted;
    /// - any other peer, even one that completes TLS perfectly, is refused.
    ///
    /// The refusals are the interesting direction. A host that accepted everything would
    /// look identical here if the probe only ever tested the paired case.
    static func checkVideoConnection(
        identity: SelfSignedIdentity,
        options: Options,
        expectAccepted: Bool
    ) async throws {
        let video = FrameChannel()
        defer { video.cancel() }

        try await video.connect(
            host: options.host,
            port: options.port,
            clientIdentity: identity,
            pinnedServerKey: options.pinnedKey,
            observed: TLSConfig.ObservedKey(),
            timeout: options.timeout
        )
        video.send(Frame(kind: .connectionRole, payload: Data([ConnectionRole.video.rawValue])))

        // A short settle, because the refusal races this check: the host cancels the
        // connection as soon as it reads the role, and that surfaces asynchronously.
        try? await Task.sleep(for: .milliseconds(600))

        let refused = video.hasEnded
        let label = expectAccepted ? "authorized client" : "unauthorized client"
        if refused == expectAccepted {
            throw ProbeError(message: """
                video connection with the \(label) was \(refused ? "refused" : "accepted"), \
                which is the opposite of what it should be. \
                \(expectAccepted
                    ? "A paired client's video connection is being rejected — the host is not matching the control session's client key."
                    : "An unpaired peer got a video connection. Anyone who can reach the port can watch the screen.")
                """)
        }
        log("video connection with the \(label) was \(refused ? "refused" : "accepted") ✓")
    }

    // MARK: - Video receive

    /// The NALU length prefix width assumed when walking an AVCC payload.
    ///
    /// ``VideoStreamConfig`` does not carry this. The width belongs to the format
    /// description rather than to the stream: the host reads it out of
    /// `CMVideoFormatDescriptionGetH264ParameterSetAtIndex` and passes it along internally
    /// (`EncodedFrame.nalUnitHeaderLength` in `MacCastHost/Capture/VideoEncoder.swift`), and
    /// its default is 4. Four is what every H.264 format description VideoToolbox produces
    /// reports, and it is what the wire carries, so 4 is assumed here. A host that emitted
    /// some other width could not say so in the current protocol — this constant is the
    /// place that would have to change.
    static let assumedNALUHeaderLength = 4

    /// Walks an AVCC payload's length prefixes and returns how many NALUs it holds.
    ///
    /// This is the check that matters most for a payload nobody is decoding yet: length
    /// prefixes are what the decoder consumes, so a payload that does not tile exactly is a
    /// picture that fails to decode — or, worse, one that decodes into garbage because a
    /// prefix was read out of the middle of another NALU. Naming the byte offset here is far
    /// closer to the cause than the decoder's eventual complaint.
    ///
    /// Offsets are counted from `data.startIndex`, never from zero. `EncodedVideoFrame`
    /// copies its body out of the frame decoder's buffer, so its `Data` starts at 0 today —
    /// but `EncodedVideoFrame.init(decoding:)` is itself written around a non-zero-based
    /// slice, and that assumption has already caused one bug in this codebase.
    static func avccNALUCount(_ data: Data, lengthSize: Int) throws -> Int {
        let base = data.startIndex
        var cursor = base
        var count = 0

        while cursor < data.endIndex {
            guard data.endIndex - cursor >= lengthSize else {
                throw ProbeError(message: """
                    AVCC payload leaves \(data.endIndex - cursor) byte(s) at offset \
                    \(cursor - base), too few for a \(lengthSize)-byte length prefix — the NALUs \
                    do not tile the payload
                    """)
            }

            var length = 0
            for offset in 0..<lengthSize {
                length = (length << 8) | Int(data[cursor + offset])
            }
            let prefixAt = cursor - base
            cursor += lengthSize

            guard length > 0 else {
                throw ProbeError(message: """
                    AVCC payload has a zero-length NALU at offset \(prefixAt). A decoder rejects \
                    that outright, and an encoder that emitted it had nothing to send.
                    """)
            }
            guard data.endIndex - cursor >= length else {
                throw ProbeError(message: """
                    AVCC payload declares a \(length)-byte NALU at offset \(prefixAt) but only \
                    \(data.endIndex - cursor) byte(s) follow the prefix
                    """)
            }
            cursor += length
            count += 1
        }

        guard count > 0 else {
            throw ProbeError(message: "AVCC payload is empty — there is no NALU to decode")
        }
        return count
    }

    /// Opens a second connection, declares the video role, and reads frames for a fixed
    /// window.
    ///
    /// **The value of this mode is the distinction it draws.** Every failure below is a
    /// different break in the chain — a host that authorized but never captured, a capture
    /// that never fed the encoder, an encoder emitting frames a decoder cannot start from,
    /// a protocol mismatch in the fixed header — and all of them look identical from the
    /// outside: a client showing nothing. Each is reported for what it is, so the next step
    /// is decided by the message rather than by guessing.
    /// Checks that a live stream survived the capture source being replaced underneath it.
    ///
    /// Three things have to hold, and they fail in different ways — which is why they are
    /// three checks rather than one:
    ///
    /// 1. **The switch was actually sent.** A receive window shorter than `--switch-after`
    ///    means nothing was ever asked for, and every check below would pass vacuously
    ///    against a host that ignores switch requests entirely.
    /// 2. **A new config arrived.** Display, application and window capture produce
    ///    different-sized surfaces, and the client cannot decode the new picture until it
    ///    has the parameter sets that go with it. A host that swapped the filter without
    ///    re-sending the description would stream frames the client reads as garbage.
    /// 3. **Frames kept coming afterwards.** This is the one a user would notice: a switch
    ///    that yields a new config and then nothing is a black screen for the rest of the
    ///    session.
    ///
    /// The keyframe half of the rule is checked by the receiver itself — `ingestConfig`
    /// arms `expectedKeyframe`, so a config not followed by a keyframe fails the run
    /// wherever it happens. That is deliberately not duplicated here.
    static func checkSourceSwitches(
        _ targets: [CaptureSource],
        sent: [(source: CaptureSource, at: Date, framesBefore: Int)],
        snapshot: VideoReceiver.Snapshot
    ) throws {
        guard let last = sent.last else {
            throw ProbeError(message: """
                none of the \(targets.count) requested switch(es) were sent: the receive \
                window ended before the first was due, so this run tested nothing about \
                switching. Raise --video-recv-seconds or lower --switch-after.
                """)
        }

        guard sent.count == targets.count else {
            let missing = targets[sent.count...].map(describe).joined(separator: ", ")
            throw ProbeError(message: """
                only \(sent.count) of \(targets.count) switch(es) were sent before the \
                window ran out; \(missing) never happened. A sequence that stops early \
                tests less than it claims to.
                """)
        }

        // The stream ending soon after a switch is the most specific explanation, so it is
        // reported instead of the missing config it also caused.
        if let endedAt = snapshot.endedAt, endedAt.timeIntervalSince(last.at) < 0.5 {
            throw ProbeError(message: """
                the host ended the video connection \
                \(formatSeconds(endedAt.timeIntervalSince(last.at))) after the capture source \
                was switched to \(describe(last.source)). The client is left with no stream \
                and no way to ask for one.
                """)
        }

        // One per switch that changes the surface — not one per switch.
        //
        // A switch that moves to a differently-sized surface owes the client a fresh
        // description, because the decoder's format description no longer matches the
        // picture. A switch between two sources that composite to the *same* size owes
        // nothing: the dimensions are unchanged, VideoToolbox produces byte-identical
        // parameter sets for them, and the client's decoder stays valid — so re-sending a
        // description it already has only makes it flush a working decoder for nothing.
        //
        // Asking for one-per-switch therefore reports a correct host as broken, which is
        // what happened on the run that switched to a window and then to the application
        // owning it: TextEdit has exactly one window, so the two sources describe the same
        // picture and the one config update was right.
        //
        // The expected count comes from the catalogue's declared pixel sizes, the only place
        // the probe can learn a source's size without capturing it. A target the catalogue
        // does not describe cannot be judged either way and is reported rather than guessed
        // at: a check that silently covers less than it claims to is worse than no check.
        let expected = expectedConfigUpdates(for: sent.map(\.source), from: snapshot.firstConfigSize)
        guard snapshot.configUpdates >= expected else {
            throw ProbeError(message: """
                \(sent.count) switch(es) were sent, of which \(expected) moved to a surface of \
                a different size, and only \(snapshot.configUpdates) videoConfig update(s) \
                followed. An unannounced change leaves the client's decoder describing a \
                picture that no longer exists — it reads every frame after it as garbage.
                """)
        }

        let after = snapshot.frames - last.framesBefore
        guard after > 0 else {
            throw ProbeError(message: """
                the source was switched to \(describe(last.source)) and not one frame arrived \
                in the \(formatSeconds(Date().timeIntervalSince(last.at))) that followed. \
                The client is showing its last picture and waiting.
                """)
        }

        let path = sent.map { describe($0.source) }.joined(separator: " → ")
        log("""
            SOURCE SWITCH OK · \(path), \(snapshot.configUpdates) config update(s) \
            (\(expected) owed), \(after) frame(s) after the last switch
            """)
    }

    /// How many of these switches should each produce a `videoConfig` update.
    ///
    /// One per switch that moves to a surface of a different size, because that is the only
    /// thing that invalidates the client's decoder. Two sources of the same size produce the
    /// same parameter sets, so the client keeps decoding across the switch and there is
    /// nothing to announce.
    ///
    /// - Parameter initialSize: the size of the surface in force before the first switch,
    ///   taken from the first config the host sent. Nil if no config ever arrived, in which
    ///   case the first switch cannot be judged and does not contribute.
    static func expectedConfigUpdates(for targets: [CaptureSource], from initialSize: CGSize?) -> Int {
        // Without a catalogue there is no declared size for anything, so the conservative
        // reading is that every switch should have been announced. That can report a correct
        // host as broken, but the alternative — assuming nothing changed — would pass a host
        // that announced nothing at all, which is the failure this check exists for.
        guard let catalog = lastCatalog else { return targets.count }

        var current = initialSize
        var expected = 0
        for target in targets {
            guard let descriptor = catalog.all.first(where: { $0.source == target }) else { continue }
            if descriptor.pixelSize != current { expected += 1 }
            current = descriptor.pixelSize
        }
        return expected
    }

    /// Parses `--switch-to`, as `<kind>:<number>`.
    ///
    /// The kind is required rather than inferred, because the number alone does not say
    /// which space it is in: `18` is a plausible display ID, window ID and pid all at once,
    /// and guessing would send the host off to capture something entirely different from
    /// what was asked for — with a successful-looking switch to show for it.
    static func parseSource(_ text: String) throws -> CaptureSource {
        let parts = text.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let value = UInt32(parts[1]) else {
            throw ProbeError(message: """
                “\(text)” is not a capture source. Write it as display:<id>, app:<pid> or \
                window:<id>, e.g. app:414.
                """)
        }

        switch parts[0] {
        case "display": return .display(value)
        case "app", "application": return .application(Int32(bitPattern: value))
        case "window": return .window(value)
        default:
            throw ProbeError(message: """
                “\(parts[0])” is not a source kind. Use display, app or window.
                """)
        }
    }

    /// A capture source in words. The raw cases are meaningless in a log — a display is a
    /// number and a pid is worse.
    static func describe(_ source: CaptureSource) -> String {
        switch source {
        case .display(let id): return "display \(id)"
        case .application(let pid): return "application \(pid)"
        case .window(let id): return "window \(id)"
        case .mosaic(let layout):
            // The tiles as well as the canvas, because the interesting thing about an arrangement
            // in a log is what is in it. See ``CaptureSource/mosaic(_:)``.
            let tiles = layout.tiles.map { describe($0.source) }.joined(separator: " + ")
            return "mosaic of \(layout.tiles.count) at "
                + "\(Int(layout.canvas.width))x\(Int(layout.canvas.height)): \(tiles)"
        }
    }

    static func receiveVideoFrames(
        identity: SelfSignedIdentity,
        options: Options,
        control: FrameChannel
    ) async throws {
        let video = FrameChannel()
        defer { video.cancel() }

        try await video.connect(
            host: options.host,
            port: options.port,
            clientIdentity: identity,
            pinnedServerKey: options.pinnedKey,
            observed: TLSConfig.ObservedKey(),
            timeout: options.timeout
        )

        // Stand the channel's watchdog down: it fires `--timeout` seconds after connect, and
        // a receive window longer than that would otherwise be cut short by "timed out
        // waiting for a frame" — a message this mode must never print when the real
        // situation is simply that the window has not finished. The window is the clock here.
        video.clearTimeout()

        video.send(Frame(kind: .connectionRole, payload: Data([ConnectionRole.video.rawValue])))
        log("video connection open; receiving for \(formatSeconds(options.videoRecvSeconds))s")

        let started = Date()
        let receiver = VideoReceiver()
        // Detached so the loop cannot inherit the entry point's isolation: it runs
        // concurrently with the deadline below and has no business on the main actor.
        let reader = Task.detached { await receiver.drain(video) }

        // The window is enforced by closing the connection, not by a timeout inside `next()`
        // — a read that is already parked has no other way out, and a probe that hangs
        // instead of reporting is the one failure it cannot recover from. Polling also means
        // a host that drops the connection is reported in milliseconds rather than after the
        // whole window has run out.
        let deadline = started.addingTimeInterval(options.videoRecvSeconds)

        // Switching happens *inside* the receive window rather than before it, because the
        // thing under test is the recovery: the client is mid-stream, holding a decoder
        // built for one picture, and the host replaces that picture underneath it. A switch
        // performed before any frame arrived would prove the new source can be captured and
        // nothing about whether a live stream survives the change.
        // Evenly spaced across the window unless told otherwise, and never in the last
        // quarter: a switch sent just before the deadline would leave no window left to
        // observe the recovery in, and "no frames followed" would be the probe's fault.
        let spacing = options.switchAfter ?? options.videoRecvSeconds / Double(options.switchTargets.count + 1)
        var switches: [(source: CaptureSource, at: Date, framesBefore: Int)] = []

        while !receiver.hasFinished, Date() < deadline {
            let index = switches.count
            if index < options.switchTargets.count,
               Date().timeIntervalSince(started) >= spacing * Double(index + 1) {
                let source = options.switchTargets[index]
                let framesBefore = receiver.current.frames
                let at = Date()
                try send(.setCaptureSource(source), on: control)
                switches.append((source, at, framesBefore))
                log("""
                    sent setCaptureSource(\(describe(source))) #\(index + 1) of \
                    \(options.switchTargets.count) \
                    \(formatSeconds(at.timeIntervalSince(started))) into the window, \
                    with \(framesBefore) frame(s) already in
                    """)
            }
            try? await Task.sleep(for: .milliseconds(25))
        }

        // Marked before the cancel, so the reader can tell "the window ended" apart from
        // "the host hung up on us".
        receiver.stop()
        video.cancel()

        // The cancel resumes a parked read, so this returns at once. The bound is
        // belt-and-braces: it turns a stuck read into a report instead of a hang.
        let drainedBy = Date().addingTimeInterval(2)
        while !receiver.hasDrained, Date() < drainedBy {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if receiver.hasDrained {
            await reader.value
        } else {
            reader.cancel()
            log("the receive loop did not stop within 2s of the connection closing; reporting what arrived")
        }

        let elapsed = Date().timeIntervalSince(started)
        let snapshot = receiver.current
        reportVideoSummary(snapshot, elapsed: elapsed, window: options.videoRecvSeconds)

        // A validation failure is the most specific thing known, so it wins.
        if let failure = snapshot.failure {
            throw ProbeError(message: failure)
        }

        // Then a connection that ended before its window. Anything within a poll interval of
        // the deadline is the deadline.
        if let endedAt = snapshot.endedAt {
            let early = endedAt.timeIntervalSince(started)
            if early < options.videoRecvSeconds - 0.3 {
                throw ProbeError(message: """
                    the host ended the video connection after \(formatSeconds(early))s of a \
                    \(formatSeconds(options.videoRecvSeconds))s window: \
                    \(snapshot.endReason ?? "no reason given")
                    """)
            }
        }

        guard snapshot.frames > 0 else {
            throw ProbeError(message: noFramesMessage(snapshot, elapsed: elapsed))
        }

        guard snapshot.keyframes > 0 else {
            throw ProbeError(message: """
                \(snapshot.frames) frame(s) arrived and not one was a keyframe. A delta frame \
                refers to a picture the client never received, so its decoder has nothing to \
                apply it to and shows nothing at all.
                """)
        }

        if !options.switchTargets.isEmpty {
            try checkSourceSwitches(
                options.switchTargets,
                sent: switches,
                snapshot: snapshot
            )
        }

        log("VIDEO RECEIVE OK")
    }

    /// The summary, printed whether or not anything arrived.
    ///
    /// Printed before the failure is thrown, deliberately: the numbers are what make an
    /// empty window legible ("0 frames in 3.00s of a 3.00s window" is a different situation
    /// from "2 frames, then the connection died"), and they are the only record of a run
    /// whose outcome is a failure.
    static func reportVideoSummary(
        _ snapshot: VideoReceiver.Snapshot,
        elapsed: TimeInterval,
        window: TimeInterval
    ) {
        let average = snapshot.frames > 0 ? Double(snapshot.bytes) / Double(snapshot.frames) : 0
        log("""
            video summary: \(snapshot.frames) frame(s), \(snapshot.keyframes) keyframe(s), \
            \(snapshot.bytes) AVCC byte(s) total, \(Int(average.rounded())) byte(s) average
            """)

        let rate = elapsed > 0 ? Double(snapshot.frames) / elapsed : 0
        log(String(
            format: "video summary: %.2fs elapsed of a %.2fs window, %.1f frame(s)/s observed",
            elapsed, window, rate
        ))

        if let first = snapshot.first, let last = snapshot.last {
            log(String(
                format: "video summary: pts %.3fs → %.3fs, span %.3fs",
                first.seconds, last.seconds, last.seconds - first.seconds
            ))
        } else {
            log("video summary: no presentation timestamps — nothing was encoded")
        }

        if let config = snapshot.config {
            let expected = config.codec == .h264 ? 2 : 3
            var line = """
                video summary: config \(config.pixelWidth)×\(config.pixelHeight) \
                \(config.codec.rawValue), \(config.parameterSets.count) parameter set(s)
                """
            line += " (expected \(expected) for \(config.codec.rawValue))"
            if snapshot.configUpdates > 0 {
                line += ", plus \(snapshot.configUpdates) mid-stream update(s)"
            }
            log(line)
        } else {
            log("video summary: no videoConfig arrived, so there is nothing a decoder could start from")
        }
    }

    /// Why an empty window is empty — as far as this side of the connection can tell.
    ///
    /// The distinction is available and worth drawing, because the two cases send the reader
    /// to different places. The host sends a config the moment a video client attaches, and
    /// it only attaches once capture has produced a format description — so a config that
    /// never arrived says the capture path never got that far, while a config that did
    /// arrive says capture was running and the encoder still produced nothing.
    static func noFramesMessage(
        _ snapshot: VideoReceiver.Snapshot,
        elapsed: TimeInterval
    ) -> String {
        let base = """
            authorized, connected, but no frames arrived in \(formatSeconds(elapsed))s
            """

        guard snapshot.config == nil else {
            return """
                \(base) — the config arrived, so the host did attach this client and capture \
                was running, but not one frame came out of the encoder. That points at the \
                capture source rather than the permission: a display that is asleep, or a \
                source that is producing nothing.
                """
        }

        return """
            \(base). Not even a videoConfig arrived, and the host sends one as soon as it \
            attaches a video client — and it only attaches once capture has produced a format \
            description. So the capture path never got that far: MacCastHost is most likely \
            missing Screen Recording permission, without which the stream never starts.
            """
    }

    static func formatSeconds(_ value: TimeInterval) -> String {
        String(format: "%.2f", value)
    }

    static func postHandshake(
        _ channel: FrameChannel,
        options: Options,
        identity: SelfSignedIdentity
    ) async throws {
        // Ends the session, so everything below it is skipped rather than skipped silently:
        // the checks that follow all need a live control connection, and running them after
        // this would report the host's close as a failure of whatever came next.
        if let keycode = options.holdDrop {
            try await holdAndDrop(channel, code: keycode)
            return
        }
        if let button = options.holdButtonDrop {
            try await holdButtonAndDrop(channel, button: button)
            return
        }
        if options.drive {
            try await driveCursor(channel)
        }
        for path in options.readFiles {
            try await readFile(path, on: channel)
        }
        if options.filesBrowse {
            try await filesBrowse(options, on: channel)
        }
        if options.agentClean {
            try await agentCleanup(on: channel)
        }
        if !options.agentPrompts.isEmpty {
            try await agentChat(options, on: channel)
        }
        for action in options.actions {
            switch action {
            case .type(let text):
                try await type(text, on: channel)
            case .key(let code, let modifiers):
                try await press(code, modifiers: modifiers, on: channel)
            case .space(let direction):
                try send(.switchSpace(direction: direction), on: channel)
                try await settle(channel)
                log("sent switchSpace(\(direction.rawValue))")
            case .verifySpaces:
                try await verifySpaceSwitching(on: channel)
            case .flags(let label):
                reportFlags(label)
            }
        }
        // Before the ping, because both read from the same channel and the catalogue is the
        // time-sensitive one: it is a single unsolicited frame that arrives shortly after
        // the session becomes usable, and the pong loop would swallow it as a skip.
        if options.expectCatalog {
            try await awaitCatalog(channel)
        }

        try await pingAndExit(channel)

        // Last, and deliberately while the control session is still open: the host
        // authorizes a video connection by matching it to a *live* authorized control
        // session, so closing this one first would test nothing.
        if options.checkVideo {
            try await checkVideoConnection(
                identity: identity,
                options: options,
                expectAccepted: true
            )
        }

        // A switch sequence is judged against the sizes the catalogue declares, because the
        // only thing that invalidates a client's decoder is the surface *changing*: two
        // sources that composite to the same size owe nothing, and a check that does not know
        // that demands an update the host is right not to send. See
        // ``expectedConfigUpdates(for:from:)``.
        //
        // The catalogue is pushed unsolicited a few milliseconds after the session opens and
        // is not guaranteed to beat the pong, so a run that never reads the control channel
        // again — and a receive window is exactly that — can miss it entirely and fall back
        // to guessing. Asking for it here, while the control channel is still the thing being
        // read, is what keeps the check below meaning what it says.
        if !options.switchTargets.isEmpty, lastCatalog == nil {
            try await awaitCatalog(channel)
        }

        // Also while the control session is still open, and for the same reason. Reception
        // comes last because it is the slow one: the accept/refuse check above is over in
        // well under a second, and running it first means a refusal is reported as a
        // refusal rather than as an empty receive window.
        if options.videoRecv {
            // The accept check cancels its own video connection, and the host detaches that
            // peer asynchronously. Without a pause the new connection can be attached before
            // the old one's detach lands, and the two orderings are not equivalent on the
            // host side.
            if options.checkVideo {
                try? await Task.sleep(for: .milliseconds(300))
            }
            try await receiveVideoFrames(identity: identity, options: options, control: channel)
        }
        channel.cancel()
    }

    /// Moves the pointer through the host and checks the **system cursor** actually went
    /// where it was told.
    ///
    /// This is the whole injection chain verified from outside: probe → TCP → TLS → session
    /// → command router → injector → `CGEvent` → the real cursor. The probe runs on the
    /// host's own machine, so it can read the result directly instead of assuming it.
    ///
    /// Expected positions are computed here from `CGDisplayBounds` — independently of the
    /// host's own transform — so a shared arithmetic mistake cannot make both agree.
    ///
    /// They are *display* coordinates, though, and the host maps input through whatever it is
    /// capturing. Those are the same thing only while the display is what is being captured,
    /// and it need not be: the host deliberately goes on capturing the last client's source
    /// after that client leaves, and this probe opens no video connection, so it never
    /// triggers the default-source reset that a video client would. Run it after a
    /// source-switch test and the host is still mapping through the window that test ended
    /// on while the arithmetic below is still the display's — a large, exactly reproducible
    /// offset that reads as a broken mapping and is not one.
    ///
    /// So a failed first pass is not the result, it is the cue to put the host back on the
    /// display and measure again. See ``adoptMainDisplay(_:bounds:)``.
    static func driveCursor(_ channel: FrameChannel) async throws {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        log("driving the cursor on a \(Int(bounds.width))×\(Int(bounds.height))pt display")

        var samples = try await measureMapping(channel, bounds: bounds)
        var failures = samples.filter { $0.drift > Self.cursorTolerance }.count

        if failures > 0 {
            try await adoptMainDisplay(channel, bounds: bounds)
            samples = try await measureMapping(channel, bounds: bounds)
            failures = samples.filter { $0.drift > Self.cursorTolerance }.count
        }

        guard failures == 0 else {
            let base = """
                \(failures) of \(samples.count) moves did not land, both before and after \
                asking MacCastHost to capture the main display. If the cursor did not move at \
                all, it is almost certainly missing Accessibility permission — without it \
                every synthetic event is discarded silently.
                """
            let hint = mappingHint(samples, bounds: bounds)
            throw ProbeError(message: hint.isEmpty ? base : base + " " + hint)
        }
        log("cursor control verified")
    }

    /// One measured move: where it was meant to land, and where the cursor is.
    struct CursorSample {
        let expected: CGPoint
        let actual: CGPoint

        /// Points off, on whichever axis is worse. A mapping error need not be diagonal, and
        /// taking the larger axis is what keeps a pure scale error showing up as a distance
        /// rather than being averaged away against an axis that happens to be right.
        var drift: CGFloat { max(abs(actual.x - expected.x), abs(actual.y - expected.y)) }
    }

    /// Sends each target, reads the cursor back, and reports every one of them.
    ///
    /// Reports rather than throws, so that a caller which is going to retry gets the
    /// measurements from the failed pass too — the first pass's numbers are what name the
    /// wrong rectangle when the second pass fails as well.
    ///
    /// Normalized (0,0) is the top-left of the captured content, so the expected global point
    /// is the display's origin plus the fraction of its size.
    static func measureMapping(
        _ channel: FrameChannel,
        bounds: CGRect
    ) async throws -> [CursorSample] {
        let targets: [(Double, Double)] = [(0.5, 0.5), (0.25, 0.75), (0.9, 0.1), (0.1, 0.9)]
        var samples: [CursorSample] = []

        for (x, y) in targets {
            try send(.mouseMove(to: NormalizedPoint(x: x, y: y)), on: channel)
            try await settle(channel)

            let sample = CursorSample(
                expected: CGPoint(
                    x: bounds.minX + bounds.width * x,
                    y: bounds.minY + bounds.height * y
                ),
                actual: CGEvent(source: nil)?.location ?? .zero
            )
            samples.append(sample)

            if sample.drift <= Self.cursorTolerance {
                log(String(
                    format: "(%.2f, %.2f) → (%.0f, %.0f) ✓",
                    x, y, sample.actual.x, sample.actual.y
                ))
            } else {
                log(String(
                    format: "(%.2f, %.2f) → expected (%.0f, %.0f) but cursor is at (%.0f, %.0f) — off by %.0fpt",
                    x, y, sample.expected.x, sample.expected.y,
                    sample.actual.x, sample.actual.y, sample.drift
                ))
            }
        }
        return samples
    }

    /// Puts the host back on the main display, and waits until that is observable.
    ///
    /// **The wait is the point.** The host applies a switch in a detached task, so the pong
    /// ``settle(_:)`` waits for proves only that the command was received; the stream rebuild
    /// and the transform that follows it can still be in flight when the next measurement is
    /// taken, and the second pass would then fail for a reason that is entirely about timing.
    ///
    /// The observable is the middle of the display, which is the one target that can be
    /// polled without knowing which mapping is in force — it is a point either way. This
    /// reports nothing on success and throws only when the wait runs out, because the caller
    /// re-measures and reports what it finds; a switch that worked and a mapping that is
    /// still wrong are told apart by those measurements, not here.
    static func adoptMainDisplay(_ channel: FrameChannel, bounds: CGRect) async throws {
        log("asking the host to capture the main display, which is what these expectations assume")
        try send(.setCaptureSource(.display(UInt32(CGMainDisplayID()))), on: channel)

        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let deadline = Date().addingTimeInterval(Self.displayAdoptionTimeout)
        var actual = CGPoint.zero

        while Date() < deadline {
            try send(.mouseMove(to: NormalizedPoint(x: 0.5, y: 0.5)), on: channel)
            try await settle(channel)
            actual = CGEvent(source: nil)?.location ?? .zero
            if max(abs(actual.x - centre.x), abs(actual.y - centre.y)) <= Self.cursorTolerance {
                log("the host is capturing the main display")
                return
            }
        }

        throw ProbeError(message: """
            asked MacCastHost to capture the main display and the cursor never started \
            landing where that mapping puts it: (0.50, 0.50) should be the middle of the \
            display at (\(Int(centre.x)), \(Int(centre.y))) and the cursor stayed at \
            (\(Int(actual.x)), \(Int(actual.y))) for \(Int(Self.displayAdoptionTimeout))s. \
            Either the host could not switch — no Screen Recording permission, or the display \
            is gone — or it is not applying the transform it reports for the source it is \
            capturing.
            """)
    }

    /// Names the rectangle the host was mapping for, when the measurements fit one.
    ///
    /// **This is what tells the two remaining causes apart.** "The mapping is broken" and
    /// "the host is mapping for a source these expectations know nothing about" fail
    /// identically, and the difference is entirely in the rectangle: recovering it turns
    /// "off by 21pt" into a frame that can be looked up in the host's catalogue. Two
    /// well-separated points on each axis are enough, because a normalized→screen mapping is
    /// affine, and the four targets always are.
    static func mappingHint(_ samples: [CursorSample], bounds: CGRect) -> String {
        let byX = samples.sorted { $0.expected.x < $1.expected.x }
        let byY = samples.sorted { $0.expected.y < $1.expected.y }
        guard let left = byX.first, let right = byX.last,
              let top = byY.first, let bottom = byY.last,
              right.expected.x > left.expected.x, bottom.expected.y > top.expected.y
        else { return "" }

        // The cursor's travel per unit of aim, scaled back up to the whole display: a mapping
        // that used a 1400pt-wide rectangle for a 1512pt display has a slope of 1400/1512,
        // and multiplying that by the display's width recovers the 1400.
        let width = (right.actual.x - left.actual.x)
            / (right.expected.x - left.expected.x) * bounds.width
        let height = (bottom.actual.y - top.actual.y)
            / (bottom.expected.y - top.expected.y) * bounds.height
        let originX = left.actual.x - width / bounds.width * left.expected.x
        let originY = top.actual.y - height / bounds.height * top.expected.y

        return "The moves land on a \(Int(width.rounded()))×\(Int(height.rounded()))pt rectangle at "
            + "(\(Int(originX.rounded())), \(Int(originY.rounded()))) rather than the display's "
            + "\(Int(bounds.width))×\(Int(bounds.height)) at "
            + "(\(Int(bounds.minX)), \(Int(bounds.minY))) — so the host is mapping for a source "
            + "that is not the display, which is the signature of an earlier client's source "
            + "switch rather than of a broken mapping."
    }

    /// Types through Unicode injection. Verification is the caller's: the text lands in
    /// whatever has focus, so only a test that controls the focused app can confirm it.
    static func type(_ text: String, on channel: FrameChannel) async throws {
        try send(.textInput(text), on: channel)
        try await settle(channel)
        log("sent textInput (\(text.count) chars)")
    }

    static func press(_ code: UInt16, modifiers: Modifiers, on channel: FrameChannel) async throws {
        try send(.keyDown(keyCode: code, modifiers: modifiers), on: channel)
        try send(.keyUp(keyCode: code, modifiers: modifiers), on: channel)
        try await settle(channel)
        if modifiers.isEmpty {
            log("sent keyDown/keyUp for keycode \(code)")
        } else {
            log("sent keyDown/keyUp for keycode \(code) with modifiers \(modifiers.rawValue)")
        }
    }

    static func send(_ command: RemoteCommand, on channel: FrameChannel) throws {
        channel.send(Frame(kind: .command, payload: try MessageCodec.encode(command)))
    }

    /// Reads a file the way the browser reads one, and reports what came back.
    ///
    /// **The one part of the file browser nothing else here can reach.** A preview is not a
    /// command and not a frame kind — it is a request and a stream of answers on the control
    /// channel — so the rest of this probe can prove the connection works and say nothing at all
    /// about whether a picture arrives as a picture or as a screenful of replacement characters.
    ///
    /// A terminal first, because the host answers a read only for a session this client owns. The
    /// shell is left running afterwards: closing it is a second round trip this does not need, and
    /// the connection goes away at the end of the run anyway.
    static func readFile(_ path: String, on channel: FrameChannel) async throws {
        channel.send(Frame(
            kind: .terminalRequest,
            payload: try MessageCodec.encode(TerminalRequest.create)
        ))

        var sessionID: UUID?
        for _ in 0..<Self.maxSkippedFrames {
            let frame = try await channel.next()
            guard frame.kind == .terminalEvent else { noteSkipped(frame); continue }
            switch try MessageCodec.decode(TerminalEvent.self, from: frame.payload) {
            case .created(let info):
                sessionID = info.id
            case .failed(_, let message):
                throw ProbeError(message: "the host would not open a shell: \(message)")
            default:
                continue
            }
            break
        }
        guard let sessionID else {
            throw ProbeError(message: "no terminal was created, so there is nothing to read through")
        }
        // Handed back on the way out, including on the way out of a failure. A host keeps a shell
        // alive across disconnects on purpose — so a phone that reconnects finds its terminal
        // where it left it — which means a probe that leaks one leaks it for good: a handful of
        // runs and every later one fails on the host's per-client session limit instead of
        // testing anything.
        let release = try MessageCodec.encode(TerminalRequest.close(sessionID: sessionID))
        defer { channel.send(Frame(kind: .terminalRequest, payload: release)) }

        let started = Date()
        channel.send(Frame(
            kind: .terminalRequest,
            payload: try MessageCodec.encode(TerminalRequest.readFile(sessionID: sessionID, path: path))
        ))

        var data = Data()
        var kind: RemoteFileKind?
        var totalBytes = 0
        var chunks = 0
        // Its own bound rather than `maxSkippedFrames`. That one is sized for "how many frames
        // might arrive before the one I want" on a quiet channel; this is a *stream*, and a
        // picture at the eight megabyte cap is two hundred and fifty-six pieces of it.
        let maxPieces = 1024
        for _ in 0..<maxPieces {
            let frame = try await channel.next()
            guard frame.kind == .terminalEvent else { noteSkipped(frame); continue }
            switch try MessageCodec.decode(TerminalEvent.self, from: frame.payload) {
            case .fileContents(let id, let answered, let eventKind, let offset, let total, let piece, let isLast):
                guard id == sessionID, answered == path else { continue }
                // Checked rather than overwritten: the kind rides on every piece and is meant to be
                // the same value every time, so a host that changed its mind mid-file would be
                // caught here rather than showing up as a picture decoded from the wrong bytes.
                if let kind, kind != eventKind {
                    throw ProbeError(message: "the kind changed mid-file: \(kind) then \(eventKind)")
                }
                kind = eventKind
                totalBytes = total
                // The offset is what makes this a test of the chunking rather than a test of the
                // transport: pieces joined in the wrong order, or a repeated one, would still sum
                // to the right length and be the wrong file.
                guard offset == data.count else {
                    throw ProbeError(message: "piece arrived at offset \(offset), expected \(data.count)")
                }
                data.append(piece)
                chunks += 1
                if isLast {
                    let elapsed = Date().timeIntervalSince(started)
                    let shown = (kind ?? .text).rawValue
                    let whole = data.count >= totalBytes ? "whole" : "TRUNCATED"
                    log("""
                        \(path) · \(shown) · \(data.count) of \(totalBytes) bytes \
                        (\(whole)) in \(chunks) piece(s), \(String(format: "%.0f", elapsed * 1000))ms
                        """)
                    if (kind ?? .text) == .text, data.count < 4096 {
                        log("  first line: \(String(decoding: data.prefix(200), as: UTF8.self).split(separator: "\n").first ?? "")")
                    }
                    return
                }
            case .browseFailure(_, let about, let message):
                guard about == path else { continue }
                throw ProbeError(message: "the host refused \(path): \(message)")
            default:
                continue
            }
        }
        throw ProbeError(message: "\(path) never finished arriving after \(maxPieces) frames")
    }

    /// An answer as the log spells it, since the verdict is an enum with a payload rather than a
    /// raw value: a chosen option is an allow that says which one.
    static func name(of decision: AgentApprovalDecision) -> String {
        switch decision {
        case .allow: return "allow"
        case .deny: return "deny"
        case .choose(let options): return "choose(\(options.joined(separator: ", ")))"
        }
    }

    /// Browses the Mac's files through a scope with no shell behind it.
    ///
    /// The lane the Mac terminals screen's own Files screen uses, and the one thing here that
    /// proves it: every other file check in this probe opens a terminal first, because that used
    /// to be the only thing a browse request could name. This one sends a scope id the client
    /// made, nothing is created on the Mac, and a listing that comes back is the whole proof.
    static func filesBrowse(_ options: Options, on channel: FrameChannel) async throws {
        let scope = UUID()
        channel.send(Frame(
            kind: .terminalRequest,
            payload: try MessageCodec.encode(TerminalRequest.startBrowser(id: scope))
        ))
        channel.send(Frame(
            kind: .terminalRequest,
            payload: try MessageCodec.encode(TerminalRequest.listDirectory(sessionID: scope, path: nil))
        ))

        var listedPath: String?
        var entries: [RemoteDirectoryEntry] = []
        for _ in 0..<Self.maxSkippedFrames {
            let frame = try await channel.next()
            guard frame.kind == .terminalEvent else { noteSkipped(frame); continue }
            switch try MessageCodec.decode(TerminalEvent.self, from: frame.payload) {
            case .directory(let id, let path, let found, _) where id == scope:
                listedPath = path
                entries = found
            case .browseFailure(let id, _, let message) where id == scope:
                throw ProbeError(message: "the host would not list with no shell open: \(message)")
            case .failed(_, let message):
                throw ProbeError(message: "the host refused the browsing scope: \(message)")
            default:
                continue
            }
            break
        }
        guard let listedPath else {
            throw ProbeError(message: "no listing arrived for the browsing scope")
        }
        let first = entries.prefix(5).map(\.name).joined(separator: ", ")
        log("FILES LIST \(listedPath) · \(entries.count) entries · first: \(first)")

        guard let file = options.filesFile else {
            log("FILES OK")
            return
        }

        channel.send(Frame(
            kind: .terminalRequest,
            payload: try MessageCodec.encode(TerminalRequest.readFile(sessionID: scope, path: file))
        ))
        var data = Data()
        var kind: RemoteFileKind?
        var totalBytes = 0
        for _ in 0..<1024 {
            let frame = try await channel.next()
            guard frame.kind == .terminalEvent else { noteSkipped(frame); continue }
            switch try MessageCodec.decode(TerminalEvent.self, from: frame.payload) {
            case .fileContents(let id, let answered, let eventKind, _, let total, let piece, let isLast):
                guard id == scope, answered == file else { continue }
                kind = eventKind
                totalBytes = total
                data.append(piece)
                if isLast {
                    let shown = (kind ?? .text).rawValue
                    log("FILES READ \(file) · \(shown) · \(data.count) of \(totalBytes) bytes")
                    log("FILES OK")
                    return
                }
            case .browseFailure(let id, _, let message) where id == scope:
                throw ProbeError(message: "the host refused \(file): \(message)")
            default:
                continue
            }
        }
        throw ProbeError(message: "\(file) never finished arriving")
    }

    /// Lists this client's chats and closes every one of them.
    ///
    /// A chat is kept across disconnects on purpose, so a check that failed mid-run leaves one
    /// behind on purpose too; without this, a few failed runs meet the host's per-client limit
    /// and every later run fails for a reason that has nothing to do with what it was testing.
    static func agentCleanup(on channel: FrameChannel) async throws {
        channel.send(Frame(kind: .agentRequest, payload: try MessageCodec.encode(AgentRequest.list)))

        var infos: [AgentSessionInfo] = []
        for _ in 0..<Self.maxSkippedFrames {
            let frame = try await channel.next()
            guard frame.kind == .agentEvent else { noteSkipped(frame); continue }
            if case .snapshot(let listed) = try MessageCodec.decode(AgentEvent.self, from: frame.payload) {
                infos = listed
                break
            }
        }
        for info in infos {
            log("closing chat \(info.id.uuidString.prefix(8)) · \(info.title) · \(info.state.rawValue)")
            channel.send(Frame(kind: .agentRequest, payload: try MessageCodec.encode(
                AgentRequest.close(sessionID: info.id)
            )))
        }
        log("agent cleanup · \(infos.count) chat(s) closed")
        // The closes are fire-and-forget; a moment's wait lets them land before the next check.
        try await Task.sleep(for: .milliseconds(300))
    }

    /// Drives a real chat session from the command line: starts it, sends each prompt, prints
    /// every event the host streams, answers approvals, and closes it on the way out.
    ///
    /// The end-to-end proof without a phone. Everything between the CLI's stdout on the Mac and
    /// this side's wire is exercised here, including the parts the UI cannot isolate: whether the
    /// process starts with the login shell's environment, whether the lines parse, and whether an
    /// approval's answer reaches the CLI.
    static func agentChat(_ options: Options, on channel: FrameChannel) async throws {
        let agentID = options.agentID ?? "claude"
        channel.send(Frame(kind: .agentRequest, payload: try MessageCodec.encode(
            AgentRequest.start(agentID: agentID, directory: options.agentDirectory)
        )))

        var sessionID: UUID?
        for _ in 0..<Self.maxSkippedFrames {
            let frame = try await channel.next()
            guard frame.kind == .agentEvent else { noteSkipped(frame); continue }
            switch try MessageCodec.decode(AgentEvent.self, from: frame.payload) {
            case .created(let info):
                sessionID = info.id
            case .failed(_, let message):
                throw ProbeError(message: "the host would not start a chat: \(message)")
            default:
                continue
            }
            break
        }
        guard let sessionID else {
            throw ProbeError(message: "no chat was created, so there is nothing to drive")
        }
        log("chat \(sessionID.uuidString.prefix(8)) · \(agentID) · \(options.agentDirectory ?? "home folder")")

        // Closed on the way out, including the way out of a failure: a host keeps a chat alive on
        // purpose, and a probe that leaks one leaks a CLI process for good.
        let close = try MessageCodec.encode(AgentRequest.close(sessionID: sessionID))
        defer { channel.send(Frame(kind: .agentRequest, payload: close)) }
        var nextPrompt = 0
        var modelSent = false
        var events = 0
        var tools = 0
        var turns = 0
        var ready = false
        var closedCleanly = false
        let started = Date()
        let deadline = started.addingTimeInterval(300)

        // A real client pings once a second in the background, and the host ends a session that
        // goes quiet on it. This check waits on minutes-long work — a login shell resolving a
        // binary, a CLI starting, a model thinking — so the ping has to keep flowing while this
        // side is not otherwise sending anything.
        let pinger = Task { [channel] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                channel.send(Frame(kind: .ping))
            }
        }
        defer { pinger.cancel() }

        func sendNextPrompt() throws {
            guard nextPrompt < options.agentPrompts.count else { return }
            let text = options.agentPrompts[nextPrompt]
            nextPrompt += 1
            log("prompt \(nextPrompt): \(text.prefix(100))")
            channel.send(Frame(kind: .agentRequest, payload: try MessageCodec.encode(
                AgentRequest.prompt(sessionID: sessionID, text: text)
            )))
        }

        // The first prompt goes now, not on `sessionReady`: a stream-json CLI does not initialise
        // until it hears from the client, so waiting for its hello before saying anything waits
        // for something that only arrives after the thing being waited for. The comment is here
        // because the first version of this check made exactly that mistake.
        try sendNextPrompt()

        while Date() < deadline {
            let frame = try await channel.next()
            if frame.kind == .pong { continue }
            guard frame.kind == .agentEvent else { noteSkipped(frame); continue }
            let event = try MessageCodec.decode(AgentEvent.self, from: frame.payload)
            switch event {
            case .modelChanged(_, let model):
                let name = model ?? "default"
                log("model now " + name)
            case .failed(_, let message):
                throw ProbeError(message: "the chat failed: \(message)")
            case .stream(let id, let stream) where id == sessionID:
                events += 1
                switch stream.payload {
                case .sessionReady(_, let cliSession, let model, let directory):
                    ready = true
                    log("ready · cli session \(cliSession?.prefix(8) ?? "?") · model \(model ?? "?") · \(directory)")
                case .turnStarted:
                    log("turn started")
                case .child:
                    break
                case .textDelta:
                    break
                case .textFinal(let text):
                    let oneLine = text.split(separator: "\n").first.map(String.init) ?? ""
                    log("reply: \(oneLine.prefix(120))")
                case .toolStarted(let call):
                    tools += 1
                    let detail = (call.detail ?? "").split(separator: "\n").first.map(String.init) ?? ""
                    log("tool \(call.title): \(detail.prefix(100))")
                case .toolFinished(_, let ok, let output, let truncated):
                    let first = (output ?? "").split(separator: "\n").first.map(String.init) ?? ""
                    log("tool \(ok ? "ok" : "FAILED")\(truncated ? " (truncated)" : ""): \(first.prefix(80))")
                case .approvalRequested(let approvalID, let call, let reason):
                    let decision: AgentApprovalDecision = options.agentApprove ? .allow : .deny
                    log("approval → \(Self.name(of: decision)): \(reason ?? call.detail ?? call.title)")
                    channel.send(Frame(kind: .agentRequest, payload: try MessageCodec.encode(
                        AgentRequest.approval(sessionID: sessionID, approvalID: approvalID, decision: decision)
                    )))
                case .approvalResolved(let approvalID, let decision):
                    log("approval resolved \(Self.name(of: decision)) (\(approvalID.prefix(8)))")
                case .turnFinished(let summary):
                    turns += 1
                    let cost = summary.costUSD.map { String(format: "$%.4f", $0) } ?? "-"
                    log("""
                        turn \(turns) finished · ok \(summary.ok)\(summary.stopped ? " (stopped)" : "") · \
                        \(cost) · \(summary.inputTokens ?? 0) in / \(summary.outputTokens ?? 0) out · \
                        \(summary.model ?? "model unknown")
                        """)
                    // The change on a session that is certainly live, between two turns, which is
                    // the case the picker is for: a switch asked for before the CLI has started is
                    // a write into a pipe that does not exist yet.
                    if let wanted = options.agentModel, turns == 1, !modelSent {
                        modelSent = true
                        log("set_model → \(wanted) (after a turn, the way the picker does it)")
                        channel.send(Frame(kind: .agentRequest, payload: try MessageCodec.encode(
                            AgentRequest.setModel(sessionID: sessionID, model: wanted)
                        )))
                    }
                    if nextPrompt < options.agentPrompts.count {
                        try sendNextPrompt()
                    } else {
                        closedCleanly = true
                    }
                case .notice(let text):
                    log("notice: \(text.prefix(120))")
                case .failure(let message):
                    log("failure: \(message.prefix(200))")
                case .sessionExited(let status):
                    log("session exited with status \(status)")
                    closedCleanly = true
                case .userPrompt:
                    break
                }
            default:
                continue
            }
            if closedCleanly { break }
        }

        let elapsed = Date().timeIntervalSince(started)
        guard ready else {
            throw ProbeError(message: "no sessionReady ever arrived: the CLI never came up")
        }
        guard closedCleanly else {
            throw ProbeError(message: "the last turn did not finish within the probe's budget")
        }
        log("""
            AGENT CHAT OK · \(turns) turn(s) · \(events) event(s) · \(tools) tool call(s) · \
            \(formatSeconds(elapsed))s
            """)
    }

    /// Sends a ping and waits for the pong, which proves the host has processed everything
    /// sent before it — the two share one connection and one handler, so they are ordered.
    /// Without this the cursor would be read before the move had been handled, and the test
    /// would fail intermittently for reasons that have nothing to do with injection.
    static func settle(_ channel: FrameChannel) async throws {
        try await awaitPong(channel, whileWaiting: "for the host")
        // The pong says the host finished; the window server applies the event slightly
        // after the post returns, so give it a moment to become observable.
        try? await Task.sleep(for: .milliseconds(60))
    }

    /// Sends a ping and reads until the pong arrives, skipping anything else.
    ///
    /// **Skipping is the point.** The control connection carries more than request/response:
    /// the host pushes the capture catalogue on it whenever a client connects and whenever an
    /// application launches or quits. A reader that insists the very next frame is the pong
    /// therefore fails on whichever connection happens to follow one — reported as a protocol
    /// error, when what it actually found is a frame it was not expecting to be interested
    /// in. A real client reads the channel as a stream and dispatches on kind;
    /// `RemoteCore.ClientSession` does exactly that, and this is the shape a probe should
    /// have had to begin with.
    ///
    /// Bounded, because an unbounded skip turns a host that never answers into a probe that
    /// hangs instead of one that reports.
    static func awaitPong(_ channel: FrameChannel, whileWaiting what: String) async throws {
        channel.send(Frame(kind: .ping))
        for _ in 0..<Self.maxSkippedFrames {
            let frame = try await channel.next()
            if frame.kind == .pong { return }
            noteSkipped(frame)
        }
        throw ProbeError(message: "no pong \(what) after skipping \(Self.maxSkippedFrames) frames")
    }

    /// The last catalogue the host pushed, and how many it has pushed.
    ///
    /// Held rather than merely logged because the push is *unsolicited* and does not wait for
    /// anything: the host sends one when a client finishes connecting, which lands somewhere
    /// in the middle of the handshake's own reads. Whichever read happens to consume it, the
    /// value is kept here so the explicit check below can report it either way — and so the
    /// count distinguishes "the host pushed one and we saw it" from "we never looked".
    ///
    /// Statics for the same reason as ``options_clientID``: one connection per process.
    nonisolated(unsafe) static var lastCatalog: CaptureCatalog?
    nonisolated(unsafe) static var catalogCount = 0

    /// Records anything the read loop was not itself waiting for.
    ///
    /// The control channel is multiplexed — a catalogue push interleaves with pongs — so a
    /// read loop has to skip frames it did not ask for. Skipping them *silently* is what
    /// makes this necessary: the catalogue is a whole feature (the client's source picker is
    /// only as good as what the host sent it), and a probe that dropped it without a word
    /// would report a clean handshake whether the host pushed a catalogue or nothing at all.
    static func noteSkipped(_ frame: Frame) {
        guard frame.kind == .catalog else { return }
        do {
            let catalog = try MessageCodec.decode(CaptureCatalog.self, from: frame.payload)
            catalogCount += 1
            lastCatalog = catalog
            log("""
                catalog pushed (#\(catalogCount)) · \(catalog.displays.count) display(s), \
                \(catalog.applications.count) application(s), \(catalog.windows.count) window(s)
                """)
            // A few names, because the counts alone cannot tell a real enumeration from a
            // mis-decoded one: an implementation that filtered the wrong field would still
            // produce three plausible numbers. The titles are the part a user would see.
            //
            // **Every line carries the source and the pixel size, and both earn their place.**
            // The source, because `--switch-to` takes `kind:id` and an id that is not on screen
            // can only be learned by guessing — or by going to `ps`, which is what this run
            // needed for the pid it switched to, and which a window id cannot be looked up in
            // at all. The size, because a capture switch whose new surface matches the old one
            // produces no videoConfig update by design, and without the sizes printed there is
            // no way to tell that case from a switch the host silently ignored.
            func line(_ kind: String, _ descriptor: CaptureSourceDescriptor) -> String {
                let size = "\(Int(descriptor.pixelSize.width))×\(Int(descriptor.pixelSize.height))"
                let detail = descriptor.subtitle.map { "\($0) · " } ?? ""
                return "  \(kind) · [\(describe(descriptor.source))] “\(descriptor.title)” \(detail)\(size)"
            }
            for descriptor in catalog.displays.prefix(2) { log(line("display", descriptor)) }
            for descriptor in catalog.applications.prefix(4) { log(line("app", descriptor)) }
            for descriptor in catalog.windows.prefix(6) { log(line("window", descriptor)) }
        } catch {
            log("a catalogue frame did not decode: \(error)")
        }
    }

    /// Fails unless the host pushed a capture catalogue.
    ///
    /// Reported from the stored value when the handshake's own reads already swallowed the
    /// push, and read for it when they have not — so this is correct whichever read won the
    /// race, rather than depending on timing that differs between a paired and a first-time
    /// connection. The bound is in frames rather than seconds for the same reason: on a
    /// first-time connection the push happens after pairing, and on a paired one it can land
    /// during the server hello, so a wall-clock wait would be measuring the wrong thing.
    static func awaitCatalog(_ channel: FrameChannel) async throws {
        if let catalog = lastCatalog {
            log("catalogue already received during the handshake")
            try reportCatalogSummary(catalog)
            return
        }

        for _ in 0..<Self.maxSkippedFrames {
            let frame = try await channel.next()
            if frame.kind == .catalog {
                noteSkipped(frame)
                try reportCatalogSummary(lastCatalog)
                return
            }
            noteSkipped(frame)
        }
        throw ProbeError(message: """
            the host pushed no capture catalogue in \(Self.maxSkippedFrames) frames. A client \
            that connects gets an empty source picker, and nothing on either side says why.
            """)
    }

    private static func reportCatalogSummary(_ catalog: CaptureCatalog?) throws {
        guard let catalog else {
            throw ProbeError(message: "the host pushed a catalogue, but it did not decode")
        }
        // An empty catalogue is the more interesting failure of the two: the push arrived,
        // so the wiring is right, but the host's enumeration returned nothing. That is
        // exactly what a denied Screen Recording permission looks like from this side, and
        // it looks like success to every check that only asks whether a catalogue arrived.
        guard !catalog.all.isEmpty else {
            throw ProbeError(message: """
                the catalogue decoded but lists nothing capturable — the host read its source \
                list and got an empty one back, which is what a denied Screen Recording \
                permission looks like from here.
                """)
        }
        log("CATALOGUE OK · \(catalog.all.count) source(s) offered")
    }

    /// How many unrelated frames may arrive before a missing pong is called missing. The
    /// catalogue is one frame per push and pushes are rare, so this is far above anything a
    /// working host produces.
    static let maxSkippedFrames = 16

    /// Slack allowed between where a move was aimed and where the cursor is. The window
    /// server rounds cursor positions, and a scaled display can land on a half point.
    static let cursorTolerance: CGFloat = 2

    /// How long the host gets to switch capture source and start mapping for it. A switch
    /// rebuilds the `SCStream` and forces a keyframe, which the host's own log puts at a few
    /// hundred milliseconds — generous enough to survive a loaded machine, short enough that
    /// a host which never switches is still reported rather than waited on.
    static let displayAdoptionTimeout: TimeInterval = 8

    // MARK: - Post-handshake

    /// Proves the session is not merely established but *usable*: a ping must come back.
    static func pingAndExit(_ channel: FrameChannel) async throws {
        try await awaitPong(channel, whileWaiting: "after the handshake")
        log("ping → pong")
        log("HANDSHAKE OK")
    }

    // MARK: - Helpers

    static func verifyPin(_ pinned: Data?, _ presented: Data) throws {
        guard let pinned else {
            // The probe takes its pin as an argument rather than persisting one, so this
            // says only that no check happened — not that pairing is what comes next.
            // Whether the host already trusts us is the host's call, in `serverHello`.
            log("no pinned server key supplied — not checking what the host presented")
            return
        }
        guard SPKI.matches(pinned, presented) else {
            throw ProbeError(message: "the host presented a key that does not match the stored pin")
        }
        log("pinned key matches")
    }

    static func randomBytes(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else { throw ProbeError(message: "no secure random") }
        return Data(bytes)
    }

    static func log(_ message: String) {
        print("[probe] \(message)")
        fflush(stdout)
    }

    // MARK: - Options

    struct Options {
        var host = "127.0.0.1"
        var port = ProtocolInfo.defaultPort
        var clientID = "probe-client"
        var clientName = "MacCast Probe"
        var pinnedKey: Data?
        var accept = false
        var resetIdentity = false
        /// Run the video-authorization checks after the control handshake.
        var checkVideo = false
        /// Open only a video connection, with no control session at all, to confirm the
        /// host refuses it.
        var videoOnly = false
        /// Receive real encoded frames on a video connection for ``videoRecvSeconds``.
        var videoRecv = false
        var videoRecvSeconds: TimeInterval = 5
        var timeout: TimeInterval = 8
        var browseOnly = false
        /// A file to read the way the browser reads one, and report on. Repeatable, so one run
        /// can ask about a text file and a picture without re-connecting between them.
        var readFiles: [String] = []
        /// Browse the Mac's files through a scope with no shell behind it: the lane the Mac
        /// terminals screen's own Files screen uses. Lists the home folder, and reads
        /// ``filesFile`` when one is named.
        var filesBrowse = false
        var filesFile: String?
        /// Start an agent chat and drive it: one prompt per turn, in order. `--agent` picks the
        /// CLI (`claude` by default) and `--agent-dir` the folder it works in.
        var agentID: String?
        var agentDirectory: String?
        var agentPrompts: [String] = []
        /// Answer a permission prompt with allow rather than deny. Off by default: a probe that
        /// approves its own asks is a probe that can run anything, which is not a thing a script
        /// nobody is watching should be able to do.
        var agentApprove = false
        /// Close every chat this client owns before doing anything else, so repeated runs of a
        /// check that failed cannot pile up sessions against the host's per-client limit.
        var agentClean = false
        /// A model to switch the chat to once it exists, to prove the picker's path end to end.
        var agentModel: String?
        var find: String?
        var browseSeconds: TimeInterval = 3
        var drive = false
        /// A keycode to press and then abandon by dropping the connection, to check that the
        /// host releases it. `55` is ⌘, the modifier whose stuck state is most obvious.
        /// Fail unless the host pushed a capture catalogue to this client.
        var expectCatalog = false
        /// Capture sources to switch through during the video receive window, in order, to
        /// test that a live stream survives having its picture replaced underneath it.
        /// Repeatable: `--switch-to window:24454 --switch-to display:1` runs a round trip.
        var switchTargets: [CaptureSource] = []
        /// Seconds into the receive window for the *first* switch. Later ones follow at the
        /// same spacing, so N switches are spread evenly across the window by default.
        var switchAfter: TimeInterval?
        var holdDrop: UInt16?
        /// A mouse button to press and then abandon by dropping the connection.
        var holdButtonDrop: MouseButton?
        var actions: [InputAction] = []

        mutating func parse(_ arguments: ArraySlice<String>) throws {
            var iterator = arguments.makeIterator()
            while let argument = iterator.next() {
                switch argument {
                case "--host":
                    guard let value = iterator.next() else { throw ProbeError(message: "--host needs a value") }
                    host = value
                case "--port":
                    guard let value = iterator.next(), let parsed = UInt16(value) else {
                        throw ProbeError(message: "--port needs a number")
                    }
                    port = parsed
                case "--id":
                    guard let value = iterator.next() else { throw ProbeError(message: "--id needs a value") }
                    clientID = value
                case "--name":
                    guard let value = iterator.next() else { throw ProbeError(message: "--name needs a value") }
                    clientName = value
                case "--pin":
                    guard let value = iterator.next() else { throw ProbeError(message: "--pin needs a value") }
                    pinnedKey = Data(hexString: value)
                    guard pinnedKey != nil else { throw ProbeError(message: "--pin is not valid hex") }
                case "--accept":
                    accept = true
                case "--browse":
                    browseOnly = true
                case "--catalog":
                    expectCatalog = true
                case "--switch-to":
                    guard let value = iterator.next() else {
                        throw ProbeError(message: "--switch-to needs a source, e.g. app:414")
                    }
                    switchTargets.append(try parseSource(value))
                case "--switch-after":
                    guard let value = iterator.next(), let parsed = TimeInterval(value), parsed > 0 else {
                        throw ProbeError(message: "--switch-after needs a positive number of seconds")
                    }
                    switchAfter = parsed
                case "--drive":
                    drive = true
                case "--hold-drop":
                    guard let value = iterator.next(), let parsed = UInt16(value) else {
                        throw ProbeError(message: "--hold-drop needs a keycode number, e.g. 55 for ⌘")
                    }
                    holdDrop = parsed
                case "--hold-button-drop":
                    guard let value = iterator.next(), let raw = UInt8(value),
                          let parsed = MouseButton(rawValue: raw)
                    else {
                        throw ProbeError(message: "--hold-button-drop needs 0 (left), 1 (right) or 2 (middle)")
                    }
                    holdButtonDrop = parsed
                case "--type":
                    guard let value = iterator.next() else { throw ProbeError(message: "--type needs a value") }
                    actions.append(.type(value))
                case "--key":
                    guard let value = iterator.next(), let parsed = UInt16(value) else {
                        throw ProbeError(message: "--key needs a keycode number")
                    }
                    actions.append(.key(parsed, []))
                case "--combo":
                    guard let value = iterator.next() else {
                        throw ProbeError(message: "--combo needs MODS:KEYCODE, e.g. cmd:0")
                    }
                    let parts = value.split(separator: ":", maxSplits: 1)
                    guard parts.count == 2, let code = UInt16(parts[1]) else {
                        throw ProbeError(message: "--combo wants MODS:KEYCODE, e.g. cmd:0 — got \(value)")
                    }
                    var modifiers: Modifiers = []
                    for name in parts[0].split(separator: "+") {
                        switch name.lowercased() {
                        case "cmd", "command": modifiers.insert(.command)
                        case "shift": modifiers.insert(.shift)
                        case "opt", "option", "alt": modifiers.insert(.option)
                        case "ctrl", "control": modifiers.insert(.control)
                        case "": break
                        default: throw ProbeError(message: "unknown modifier \(name)")
                        }
                    }
                    actions.append(.key(code, modifiers))
                case "--space":
                    guard let value = iterator.next() else { throw ProbeError(message: "--space needs left or right") }
                    guard let parsed = SpaceDirection(rawValue: value) else {
                        throw ProbeError(message: "--space must be left or right, not \(value)")
                    }
                    actions.append(.space(parsed))
                case "--verify-spaces":
                    actions.append(.verifySpaces)
                case "--flags":
                    guard let value = iterator.next() else {
                        throw ProbeError(message: "--flags needs a label, e.g. --flags BEFORE")
                    }
                    actions.append(.flags(value))
                case "--read-file":
                    guard let value = iterator.next() else {
                        throw ProbeError(message: "--read-file needs a path")
                    }
                    readFiles.append(value)
                case "--agent-model":
                    guard let value = iterator.next() else { throw ProbeError(message: "--agent-model needs a name") }
                    agentModel = value
                case "--files-browse":
                    filesBrowse = true
                case "--files-file":
                    guard let value = iterator.next() else {
                        throw ProbeError(message: "--files-file needs a path")
                    }
                    filesFile = value
                case "--agent":
                    guard let value = iterator.next() else { throw ProbeError(message: "--agent needs an id") }
                    agentID = value
                case "--agent-dir":
                    guard let value = iterator.next() else { throw ProbeError(message: "--agent-dir needs a path") }
                    agentDirectory = value
                case "--agent-prompt":
                    guard let value = iterator.next() else { throw ProbeError(message: "--agent-prompt needs text") }
                    agentPrompts.append(value)
                case "--agent-approve":
                    agentApprove = true
                case "--agent-clean":
                    agentClean = true
                case "--find":
                    guard let value = iterator.next() else { throw ProbeError(message: "--find needs a value") }
                    find = value
                case "--browse-seconds":
                    guard let value = iterator.next(), let parsed = TimeInterval(value) else {
                        throw ProbeError(message: "--browse-seconds needs a number")
                    }
                    browseSeconds = parsed
                case "--video":
                    checkVideo = true
                case "--video-only":
                    videoOnly = true
                case "--video-recv":
                    videoRecv = true
                case "--video-recv-seconds":
                    guard let value = iterator.next(), let parsed = TimeInterval(value) else {
                        throw ProbeError(message: "--video-recv-seconds needs a number of seconds")
                    }
                    guard parsed > 0 else {
                        throw ProbeError(message: "--video-recv-seconds must be greater than zero")
                    }
                    guard parsed <= 3600 else {
                        throw ProbeError(message: "--video-recv-seconds must be at most 3600")
                    }
                    videoRecvSeconds = parsed
                case "--reset":
                    resetIdentity = true
                case "--timeout":
                    guard let value = iterator.next(), let parsed = TimeInterval(value) else {
                        throw ProbeError(message: "--timeout needs a number of seconds")
                    }
                    timeout = parsed
                case "--help", "-h":
                    print(Self.usage)
                    exit(0)
                default:
                    throw ProbeError(message: "unknown argument \(argument)\n\(Self.usage)")
                }
            }
        }

        static let usage = """
        usage: MacCastProbe [--host H] [--port P] [--id ID] [--name NAME] [--pin HEX] [--accept]

          --host   hostname or IP of the Mac running MacCastHost (default 127.0.0.1)
          --port   port to connect to (default \(ProtocolInfo.defaultPort))
          --id     client device ID; must be stable across runs for the pin to match
          --name   client name shown on the host
          --pin    hex of the server's public key; omit for a first pairing
          --accept confirm the SAS code automatically (there is no UI to tap)
          --reset  destroy the stored probe identity first, forcing a fresh key
          --browse discover hosts over Bonjour and stop; makes no connection
          --find   browse, then connect to the host whose name or ID matches
          --browse-seconds  how long to browse for (default 3)
          --read-file  read a file through a terminal and report what the host said it is
          --agent  claude|codex for a chat session (default claude)
          --agent-dir  the folder the agent works in (default: the Mac's home folder)
          --agent-prompt  a prompt to send; repeat for several turns in one conversation
          --agent-approve  answer permission prompts with allow instead of deny
                       (repeatable, runs in argument order)
          --drive  move the real cursor and verify it lands where it was told
          --type   send a Unicode text injection (repeatable, runs in argument order)
          --key    send a keycode press/release (repeatable, runs in argument order)
          --combo  send a keycode with modifiers, MODS:CODE, e.g. cmd:0 (repeatable)
          --space  send switchSpace(left|right) (repeatable, runs in argument order)
          --verify-spaces  assert that at least one adjacent desktop can be activated
          --flags  print the session's held modifiers under a label, e.g. --flags BEFORE
          --video  after pairing, check the host accepts a video connection from this client
          --video-only  open only a video connection, with no control session, and expect refusal
          --video-recv  after pairing, receive real frames on a video connection and validate them
          --video-recv-seconds  how long to receive for (default 5)
        """
    }
}

/// Gathers browse events for the duration of the browse window. `HostBrowser` reports from
/// its own queue, so this is the lock that gets the results back to the script.
final class HostCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _hosts: [DiscoveredHost] = []
    private var _failure: String?

    var hosts: [DiscoveredHost] { lock.withLock { _hosts } }
    var failure: String? { lock.withLock { _failure } }

    func offer(_ event: HostBrowser.Event) {
        lock.lock()
        switch event {
        case .updated(let hosts): _hosts = hosts
        case .failed(let message): _failure = message
        case .started: break
        }
        lock.unlock()
    }
}

/// Accumulates and validates everything that arrives on the video connection.
///
/// Locked, like ``HostCollector`` above and for the same reason: the receive loop runs in a
/// task of its own while the caller enforces the window, so this is what carries the results
/// back across the boundary.
///
/// Validation happens as each frame lands rather than in a pass afterwards, because every
/// failure here is about *order* — a frame before its config, a delta before a keyframe — and
/// naming which one happened is the whole point of the mode.
final class VideoReceiver: @unchecked Sendable {
    struct Snapshot: Sendable {
        var frames = 0
        var keyframes = 0
        /// AVCC payload bytes only: what a decoder consumes, not the wire framing around it.
        var bytes = 0
        var first: VideoTimestamp?
        var last: VideoTimestamp?
        var config: VideoStreamConfig?
        var configUpdates = 0
        /// The size of the surface described *before* any switch, which is what the first
        /// switch has to be compared against. `config` cannot answer this: it is overwritten
        /// by every update, so by the time the switches are judged it describes the last
        /// surface rather than the one the sequence started from.
        var firstConfigSize: CGSize?
        /// The first validation failure, and the only one worth reporting.
        var failure: String?
        /// When the connection ended, if the host ended it rather than the window doing so.
        var endedAt: Date?
        var endReason: String?
    }

    private let lock = NSLock()
    private var snapshot = Snapshot()
    private var stopped = false
    private var drained = false
    /// Whether the next frame has to be a keyframe. True at the start of the stream and again
    /// after every config, because a config invalidates every picture the decoder holds.
    private var expectedKeyframe = true

    var current: Snapshot { lock.withLock { snapshot } }
    var hasDrained: Bool { lock.withLock { drained } }

    var hasFinished: Bool {
        lock.withLock { stopped || snapshot.failure != nil || snapshot.endedAt != nil }
    }

    /// Marks the end of the receive window.
    ///
    /// Set by the caller just before it closes the connection, so the read that fails as a
    /// result is understood as the deadline arriving rather than as the host hanging up.
    func stop() {
        lock.withLock { stopped = true }
    }

    /// Pulls frames until the caller's window ends or the connection does.
    ///
    /// Never throws: a failure here is a result to be reported, not an exception to unwind,
    /// and the loop has to survive long enough to keep counting frames after a suspicious
    /// one — the summary is more useful with the whole window in it.
    func drain(_ channel: FrameChannel) async {
        defer { lock.withLock { drained = true } }
        while !hasFinished {
            do {
                ingest(try await channel.next())
            } catch {
                recordEnd("\(error.localizedDescription)")
                return
            }
        }
    }

    // MARK: - Ingest

    /// Internal rather than private so the checks below can be driven with frames directly.
    /// They are the whole product of this mode, and the only way to see them fire before a
    /// real host sends real frames is to hand them one.
    func ingest(_ frame: Frame) {
        switch frame.kind {
        case .videoConfig:
            ingestConfig(frame.payload)
        case .videoFrame:
            ingestFrame(frame.payload)
        default:
            fail("""
                a \(frame.kind) message arrived on the video connection. That channel carries \
                only videoConfig and videoFrame, so this is a protocol error rather than a \
                stream problem.
                """)
        }
    }

    private func ingestConfig(_ payload: Data) {
        let config: VideoStreamConfig
        do {
            config = try MessageCodec.decode(VideoStreamConfig.self, from: payload)
        } catch {
            fail("the videoConfig payload did not decode as VideoStreamConfig: \(error)")
            return
        }

        guard config.pixelWidth > 0, config.pixelHeight > 0 else {
            fail("the videoConfig declares a \(config.pixelWidth)×\(config.pixelHeight) picture")
            return
        }

        guard !config.parameterSets.isEmpty,
              config.parameterSets.allSatisfy({ !$0.isEmpty })
        else {
            fail("""
                the videoConfig carries \(config.parameterSets.count) parameter set(s) and at \
                least one is empty. AVCC keeps them out of band, so an empty set leaves the \
                client unable to build a format description and unable to decode anything.
                """)
            return
        }

        lock.lock()
        defer { lock.unlock() }
        if snapshot.config != nil {
            snapshot.configUpdates += 1
        } else {
            snapshot.firstConfigSize = CGSize(width: config.pixelWidth, height: config.pixelHeight)
        }
        snapshot.config = config
        // A config change means new dimensions, new parameter sets, and a decoder whose state
        // belongs to a different picture. The host forces a keyframe for exactly this reason
        // (`VideoStreamer.updateConfig`), so whatever follows must be one.
        expectedKeyframe = true
    }

    private func ingestFrame(_ payload: Data) {
        let frame: EncodedVideoFrame
        do {
            frame = try EncodedVideoFrame(decoding: payload)
        } catch {
            // The two cases here are the ones the fixed header exists to make impossible: a
            // header that ran past the end of the payload, and a declared body length that
            // disagrees with what arrived. Both would otherwise reach a decoder as a
            // truncated picture, failing much later and much less clearly.
            fail("""
                a videoFrame payload did not decode as EncodedVideoFrame — \(error) \
                (\(payload.count) byte(s) on the wire; the fixed header alone is \
                \(EncodedVideoFrame.headerSize))
                """)
            return
        }

        do {
            _ = try Probe.avccNALUCount(frame.data, lengthSize: Probe.assumedNALUHeaderLength)
        } catch {
            let detail = (error as? Probe.ProbeError)?.message ?? "\(error)"
            fail("a videoFrame carries a malformed AVCC payload: \(detail)")
            return
        }

        lock.lock()
        defer { lock.unlock() }

        guard let config = snapshot.config else {
            recordFailureLocked("""
                a video frame arrived before any videoConfig. The config carries the codec, the \
                picture size, and the parameter sets — and AVCC keeps those out of band — so \
                without it the client cannot build a format description and cannot decode this \
                frame at all.
                """)
            return
        }

        guard frame.pixelWidth == config.pixelWidth, frame.pixelHeight == config.pixelHeight else {
            recordFailureLocked("""
                a frame is \(frame.pixelWidth)×\(frame.pixelHeight) but the config says \
                \(config.pixelWidth)×\(config.pixelHeight). The client sizes its layer from the \
                config, so the picture would be stretched or cropped.
                """)
            return
        }

        guard !expectedKeyframe || frame.isKeyframe else {
            recordFailureLocked("""
                the first frame of the stream is not a keyframe. A delta frame encodes only the \
                difference from a picture the client never received, so its decoder has nothing \
                to apply it to and shows nothing at all — the client joined mid-stream and needs \
                a keyframe to start from.
                """)
            return
        }

        let pts = frame.presentationTime
        guard pts.timescale != 0 else {
            recordFailureLocked("""
                a frame carries a presentation timestamp with a zero timescale (value \
                \(pts.value)). VideoTimestamp.seconds divides by it, so every frame would \
                present at 0s and the client would have no timing information at all.
                """)
            return
        }

        if let last = snapshot.last, pts.seconds < last.seconds {
            recordFailureLocked(String(
                format: """
                    presentation timestamps go backwards: %.3fs after %.3fs. Frames arrive in \
                    presentation order, and a client that reorders or drops on a non-monotonic \
                    timestamp shows the wrong picture at the wrong time.
                    """,
                pts.seconds, last.seconds
            ))
            return
        }

        snapshot.frames += 1
        if frame.isKeyframe { snapshot.keyframes += 1 }
        snapshot.bytes += frame.data.count
        if snapshot.first == nil { snapshot.first = pts }
        snapshot.last = pts
        expectedKeyframe = false
    }

    // MARK: - Outcomes

    /// The connection ended before the window did. The caller judges whether that was early.
    private func recordEnd(_ reason: String) {
        lock.lock()
        defer { lock.unlock() }
        // A window that ended because the caller closed the connection is not an end, and a
        // validation failure already explains the transport error that followed it.
        guard !stopped, snapshot.failure == nil, snapshot.endedAt == nil else { return }
        snapshot.endedAt = Date()
        snapshot.endReason = reason
    }

    private func fail(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        recordFailureLocked(message)
    }

    /// The first failure only: everything after it is a consequence, and a list of follow-on
    /// errors buries the cause.
    private func recordFailureLocked(_ message: String) {
        guard snapshot.failure == nil else { return }
        snapshot.failure = message
    }
}

extension DiscoveredHost {
    /// Case-insensitive match on the advertised name, or an exact match on the device ID.
    /// The name is what a human types; the ID is what a script should use, because it is
    /// the only one of the two that survives the host being renamed.
    func matches(_ query: String) -> Bool {
        let needle = query.lowercased()
        return id.lowercased() == needle || name.lowercased().contains(needle)
    }
}

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexString: String) {
        let cleaned = hexString.filter { !$0.isWhitespace }
        guard cleaned.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}
