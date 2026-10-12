import Foundation
import Testing

@testable import RemoteCore

@Suite("ClientState")
struct ClientStateTests {
    @Test("the kind byte is 0x23")
    func kindByte() {
        #expect(MessageKind.clientState.rawValue == 0x23)
    }

    @Test("the payload encodes as a one-key object")
    func payloadJSON() throws {
        let on = try MessageCodec.encode(ClientStatePayload(background: true))
        let off = try MessageCodec.encode(ClientStatePayload(background: false))
        #expect(String(decoding: on, as: UTF8.self) == #"{"background":true}"#)
        #expect(String(decoding: off, as: UTF8.self) == #"{"background":false}"#)
    }

    @Test("the payload decodes from what another platform writes")
    func payloadDecodes() throws {
        let decoded = try MessageCodec.decode(ClientStatePayload.self, from: Data(#"{"background": true}"#.utf8))
        #expect(decoded == ClientStatePayload(background: true))
    }

    @Test("the notice goes only to a host that declared it")
    func supportGate() {
        #expect(ClientStateSupport.maySend(toHostDeclared: true))
        #expect(!ClientStateSupport.maySend(toHostDeclared: false))
        #expect(!ClientStateSupport.maySend(toHostDeclared: nil))
    }

    @Test("a server hello without the flag decodes as not supported")
    func oldHostHello() throws {
        let json = #"{"serverID":"s","hostName":"Mac","protocolVersion":20,"alreadyPaired":true}"#
        let hello = try MessageCodec.decode(ServerHello.self, from: Data(json.utf8))
        #expect(hello.supportsClientState == nil)
    }

    @Test("background pauses the picture and returning resumes it")
    func backgroundThenForeground() {
        var state = ClientPictureState()
        #expect(state.clientBackground(true) == .pauseVideo)
        #expect(state.inBackground)
        #expect(state.clientBackground(false) == .resumeVideo)
        #expect(!state.inBackground)
    }

    @Test("a repeated notice does nothing")
    func repeatsAreIgnored() {
        var state = ClientPictureState()
        #expect(state.clientBackground(false) == .none)
        #expect(state.clientBackground(true) == .pauseVideo)
        #expect(state.clientBackground(true) == .none)
    }

    @Test("a picture the client paused itself stays paused after it returns")
    func userPauseSurvivesBackground() {
        var state = ClientPictureState()
        #expect(state.pictureRequested(false) == .pauseVideo)
        #expect(state.clientBackground(true) == .none)
        #expect(state.clientBackground(false) == .none)
        #expect(state.pictureRequested(true) == .resumeVideo)
    }

    @Test("a resume asked for while in the background waits for the return")
    func resumeHeldBack() {
        var state = ClientPictureState()
        _ = state.pictureRequested(false)
        _ = state.clientBackground(true)
        #expect(state.pictureRequested(true) == .none)
        #expect(state.clientBackground(false) == .resumeVideo)
    }

    @Test("a pause asked for while in the background is remembered on return")
    func pauseAskedInBackground() {
        var state = ClientPictureState()
        _ = state.clientBackground(true)
        #expect(state.pictureRequested(false) == .none)
        #expect(state.clientBackground(false) == .none)
    }

    @Test("silence limits: normal, handshake and background")
    func silenceLimits() {
        #expect(SessionSilenceLimits.limit(isAuthorized: true, clientInBackground: false) == 60)
        #expect(SessionSilenceLimits.limit(isAuthorized: true, clientInBackground: true) == 180)
        #expect(SessionSilenceLimits.limit(isAuthorized: false, clientInBackground: true) == 30)
        #expect(SessionSilenceLimits.approval == 120)
    }
}
