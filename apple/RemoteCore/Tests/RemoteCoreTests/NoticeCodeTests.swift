import Foundation
import Testing

@testable import RemoteCore

@Suite("Notice codes")
struct NoticeCodeTests {
    @Test("a known code is read from the payload, an unknown or missing one is nil")
    func knownCode() {
        #expect(NoticePayload(message: "m", code: "capture-recovery-failed").knownCode == .captureRecoveryFailed)
        #expect(NoticePayload(message: "m", code: "from-a-newer-host").knownCode == nil)
        #expect(NoticePayload(message: "m").knownCode == nil)
    }

    @Test("every code is unique and survives the wire")
    func codesAreUnique() throws {
        #expect(Set(NoticeCode.allCases.map(\.rawValue)).count == NoticeCode.allCases.count)
        for code in NoticeCode.allCases {
            let data = try MessageCodec.encode(NoticePayload(message: "m", code: code.rawValue))
            #expect(try MessageCodec.decode(NoticePayload.self, from: data).knownCode == code)
        }
    }

    @Test("a notice from before the code field still decodes")
    func oldShape() throws {
        let data = Data(#"{"message":"This Mac is locked.","symbol":"lock.fill","lockedDisplayID":1}"#.utf8)
        let notice = try MessageCodec.decode(NoticePayload.self, from: data)
        #expect(notice.code == nil)
        #expect(notice.message == "This Mac is locked.")
    }
}
