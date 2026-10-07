import Testing

@testable import MacCastKit

@Suite struct AgentFolderPathDisplayTests {
    @Test func theHomeFolderIsATilde() {
        #expect(AgentFolderPath.display("/Users/me", home: "/Users/me") == "~")
    }

    @Test func aFolderInsideHomeStartsWithATilde() {
        #expect(AgentFolderPath.display("/Users/me/Desktop/app", home: "/Users/me") == "~/Desktop/app")
    }

    @Test func aSiblingWithTheSamePrefixIsNotInsideHome() {
        #expect(AgentFolderPath.display("/Users/me2/x", home: "/Users/me") == "/Users/me2/x")
    }

    @Test func withoutAKnownHomeThePathIsUnchanged() {
        #expect(AgentFolderPath.display("/Volumes/Backup", home: nil) == "/Volumes/Backup")
        #expect(AgentFolderPath.display("/Users/me", home: "/") == "/Users/me")
    }
}
