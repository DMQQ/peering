import Testing

@testable import PeeringKit

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

@Suite struct AgentFolderPathUserHomeTests {
    @Test func aFolderInsideAUserFolderNamesIt() {
        #expect(AgentFolderPath.userHome(containing: "/Users/me/Desktop/app") == "/Users/me")
        #expect(AgentFolderPath.userHome(containing: "/Users/me") == "/Users/me")
    }

    @Test func thingsOutsideAUserFolderHaveNone() {
        #expect(AgentFolderPath.userHome(containing: "/") == nil)
        #expect(AgentFolderPath.userHome(containing: "/Users") == nil)
        #expect(AgentFolderPath.userHome(containing: "/Volumes/Backup") == nil)
        #expect(AgentFolderPath.userHome(containing: nil) == nil)
    }
}
