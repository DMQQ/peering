import Testing

@testable import PeeringKit

struct AgentGitLocatorTests {
    private func locate(existing: Set<String>, developer: String? = nil) -> String? {
        AgentGitLocator.executable(exists: existing.contains, developerDirectory: developer)
    }

    @Test func theSystemGitIsUsedWhenTheSelectedDeveloperDirectoryHasOne() {
        let found = locate(existing: ["/Applications/Xcode.app/Contents/Developer/usr/bin/git"], developer: "/Applications/Xcode.app/Contents/Developer")
        #expect(found == "/usr/bin/git")
    }

    @Test func theSystemGitIsUsedWhenTheCommandLineToolsAreInstalled() {
        #expect(locate(existing: ["/Library/Developer/CommandLineTools/usr/bin/git"]) == "/usr/bin/git")
    }

    @Test func theStubIsNeverUsedWithoutDeveloperTools() {
        #expect(locate(existing: ["/usr/bin/git"]) == nil)
    }

    @Test func aPackageManagerGitIsTheFallback() {
        #expect(locate(existing: ["/usr/bin/git", "/opt/homebrew/bin/git"]) == "/opt/homebrew/bin/git")
        #expect(locate(existing: ["/usr/local/bin/git"]) == "/usr/local/bin/git")
    }

    @Test func aStaleDeveloperDirectoryDoesNotCount() {
        #expect(locate(existing: [], developer: "/Applications/Gone.app/Contents/Developer") == nil)
    }
}
