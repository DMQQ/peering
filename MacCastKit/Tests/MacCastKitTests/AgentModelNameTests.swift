import Testing

@testable import MacCastKit

struct AgentModelNameTests {
    @Test func dropsVendorPrefixAndDatedSuffix() {
        #expect(AgentModelName.short("claude-opus-4-1-20250805") == "opus-4.1")
        #expect(AgentModelName.short("claude-sonnet-4-5") == "sonnet-4.5")
        #expect(AgentModelName.short("claude-sonnet-5-5") == "sonnet-5.5")
        #expect(AgentModelName.short("claude-haiku-4-5-20251001") == "haiku-4.5")
    }

    @Test func leavesOtherNamesAlone() {
        #expect(AgentModelName.short("gpt-5-codex") == "gpt-5-codex")
        #expect(AgentModelName.short("o3-2025") == "o3-2025")
    }

    @Test func aliasMatchesTheDatedNameItResolvesTo() {
        #expect(AgentModelName.isCurrent("opus", current: "claude-opus-4-1-20250805"))
        #expect(AgentModelName.isCurrent("claude-haiku-4-5", current: "claude-haiku-4-5-20251001"))
        #expect(!AgentModelName.isCurrent("haiku", current: "claude-opus-4-1-20250805"))
        #expect(!AgentModelName.isCurrent("opus", current: nil))
    }

    @Test func claudeGetsItsAliasesAndOthersGetTheMacsList() {
        #expect(AgentModelName.suggestions(agentID: "claude", hostChoices: ["x"]) == ["claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-4-5"])
        #expect(AgentModelName.suggestions(agentID: "codex", hostChoices: ["gpt-5", "o3"]) == ["gpt-5", "o3"])
    }

    @Test func pickerIsOfferedOnlyForAgentsThatTakeAModelAndAHostThatCanSetIt() {
        #expect(AgentModelName.offersPicker(agentID: "claude", hostSupportsPicker: true))
        #expect(AgentModelName.offersPicker(agentID: "codex", hostSupportsPicker: true))
        #expect(!AgentModelName.offersPicker(agentID: "opencode", hostSupportsPicker: true))
        #expect(!AgentModelName.offersPicker(agentID: "claude", hostSupportsPicker: false))
    }
}
