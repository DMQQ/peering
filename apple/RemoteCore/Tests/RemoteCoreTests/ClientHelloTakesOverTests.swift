import Foundation
import Testing
@testable import RemoteCore

struct ClientHelloTakesOverTests {
    @Test func aHelloFromBeforeTheFieldDecodesAsNotTakingOver() throws {
        let old = #"{"clientID":"c","clientName":"n","protocolVersion":20,"wantsPairing":false}"#
        let hello = try JSONDecoder().decode(ClientHello.self, from: Data(old.utf8))
        #expect(hello.takesOver == nil)
    }

    @Test func theRequestSurvivesAnEncodeAndDecode() throws {
        let hello = ClientHello(clientID: "c", clientName: "n", protocolVersion: 20, wantsPairing: false, takesOver: true)
        let decoded = try JSONDecoder().decode(ClientHello.self, from: JSONEncoder().encode(hello))
        #expect(decoded.takesOver == true)
    }

    @Test func theRefusalCodeIsStableBecauseAnOlderPeerMatchesIt() {
        #expect(ErrorPayload.anotherDeviceCode == "anotherDevice")
    }
}
