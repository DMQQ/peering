import Foundation
import Testing

@testable import RemoteCore

@Suite("Video codec negotiation")
struct VideoCodecNegotiationTests {
    @Test func aClientWithNoListGetsTheHostsChoice() {
        #expect(VideoCodec.negotiated(preferred: .hevc, declared: nil) == .hevc)
        #expect(VideoCodec.negotiated(preferred: .hevc, declared: []) == .hevc)
    }

    @Test func aClientThatDecodesTheHostsChoiceGetsIt() {
        #expect(VideoCodec.negotiated(preferred: .hevc, declared: ["h264", "hevc"]) == .hevc)
        #expect(VideoCodec.negotiated(preferred: .h264, declared: ["HEVC", "H264"]) == .h264)
    }

    @Test func aClientThatCannotDecodeHevcGetsH264() {
        #expect(VideoCodec.negotiated(preferred: .hevc, declared: ["h264"]) == .h264)
    }

    @Test func aListOfUnknownCodecsFallsBackToH264() {
        #expect(VideoCodec.negotiated(preferred: .hevc, declared: ["av1", "vp9"]) == .h264)
    }

    @Test func theNewHelloFieldsAreAdditive() throws {
        let hello = ClientHello(
            clientID: "c", clientName: "Pixel", protocolVersion: 1, wantsPairing: false,
            clientPlatform: "android", videoCodecs: ["h264"]
        )
        let decoded = try MessageCodec.decode(ClientHello.self, from: try MessageCodec.encode(hello))
        #expect(decoded.videoCodecs == ["h264"])
        #expect(decoded.clientPlatform == "android")

        let old = ClientHello(clientID: "c", clientName: "iPhone", protocolVersion: 1, wantsPairing: false)
        let oldDecoded = try MessageCodec.decode(ClientHello.self, from: try MessageCodec.encode(old))
        #expect(oldDecoded.videoCodecs == nil)
        #expect(oldDecoded.clientPlatform == nil)

        let server = ServerHello(serverID: "s", hostName: "Mac", protocolVersion: 1, alreadyPaired: true, hostPlatform: "macos")
        let serverDecoded = try MessageCodec.decode(ServerHello.self, from: try MessageCodec.encode(server))
        #expect(serverDecoded.hostPlatform == "macos")
    }
}
