import Testing

@testable import PeeringKit

struct AgentMarkdownTableTests {
    @Test func pipesWithARuleBelowBecomeATable() {
        let blocks = AgentMarkdown.split("| Name | Qty |\n|:--|--:|\n| apple | 3 |\n| pear | 5 |\n\nafter")
        #expect(blocks == [
            .table(.init(header: ["Name", "Qty"], rows: [["apple", "3"], ["pear", "5"]], alignments: [.leading, .trailing])),
            .paragraph("after"),
        ])
    }

    @Test func aHeaderWithoutItsRuleYetStaysAParagraph() {
        #expect(AgentMarkdown.split("| Name | Qty |") == [.paragraph("| Name | Qty |")])
    }

    @Test func shortRowsArePaddedAndLongOnesTrimmed() {
        let blocks = AgentMarkdown.split("a | b\n--|--\n1 |\n1 | 2 | 3")
        #expect(blocks == [.table(.init(header: ["a", "b"], rows: [["1", ""], ["1", "2"]], alignments: [.leading, .leading]))])
    }

    @Test func anEscapedPipeStaysInItsCell() {
        let blocks = AgentMarkdown.split("| a |\n|---|\n| x \\| y |")
        #expect(blocks == [.table(.init(header: ["a"], rows: [["x | y"]], alignments: [.leading]))])
    }

    @Test func aTableInsideACodeFenceIsCode() {
        #expect(AgentMarkdown.split("```\n| a | b |\n|---|---|\n```") == [.code("| a | b |\n|---|---|")])
    }
}
