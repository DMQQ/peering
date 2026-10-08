import Testing

@testable import MacCastKit

struct AgentChatLimitTests {
    @Test func freeMayHaveThreeAndNotAFourth() {
        #expect(AgentChatLimit.allowsAnother(openChats: 0, access: .known(.free)))
        #expect(AgentChatLimit.allowsAnother(openChats: 2, access: .known(.free)))
        #expect(!AgentChatLimit.allowsAnother(openChats: 3, access: .known(.free)))
        #expect(!AgentChatLimit.allowsAnother(openChats: 7, access: .known(.free)))
    }

    @Test func aPaidPlanHasNoLimit() {
        #expect(AgentChatLimit.allowsAnother(openChats: 12, access: .known(.relay)))
        #expect(AgentChatLimit.allowsAnother(openChats: 12, access: .known(.pro)))
    }

    @Test func aPlanNotYetReadLocksNothing() {
        #expect(AgentChatLimit.allowsAnother(openChats: 9, access: .unknown))
    }
}
