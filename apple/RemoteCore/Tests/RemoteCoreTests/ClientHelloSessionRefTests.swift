import Foundation
import Testing
@testable import RemoteCore

struct ClientHelloSessionRefTests {
    @Test func aHelloFromBeforeTheFieldDecodesWithoutIt() throws {
        let old = #"{"clientID":"c","clientName":"n","protocolVersion":20,"wantsPairing":false}"#
        let hello = try JSONDecoder().decode(ClientHello.self, from: Data(old.utf8))
        #expect(hello.sessionRef == nil)
    }

    @Test func theSessionRefSurvivesAnEncodeAndDecode() throws {
        let hello = ClientHello(clientID: "c", clientName: "n", protocolVersion: 20, wantsPairing: false, sessionRef: "0a1b2c3d")
        let decoded = try JSONDecoder().decode(ClientHello.self, from: JSONEncoder().encode(hello))
        #expect(decoded.sessionRef == "0a1b2c3d")
    }
}
