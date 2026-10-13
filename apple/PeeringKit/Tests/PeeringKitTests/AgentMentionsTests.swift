import RemoteCore
import Testing

@testable import PeeringKit

struct AgentMentionsTests {
    private func entry(_ name: String, folder: Bool = false) -> RemoteDirectoryEntry {
        RemoteDirectoryEntry(name: name, isDirectory: folder, isSymlink: false, size: 0, permissions: "rw-r--r--", modified: nil)
    }

    @Test func splitTakesLeadingFileMentions() {
        let read = AgentMentions.split("@/a/b.png @/c.txt look at these")
        #expect(read.files == ["/a/b.png", "/c.txt"])
        #expect(read.rest == "look at these")
    }

    @Test func splitLeavesAMidSentenceMentionAlone() {
        let read = AgentMentions.split("see @/a/b.png please")
        #expect(read.files.isEmpty)
        #expect(read.rest == "see @/a/b.png please")
    }

    @Test func queryIsTheLastWordWhenItStartsWithAt() {
        let query = MentionQuery(draft: "read @src/ma")
        #expect(query?.typed == "src/ma")
        #expect(query?.folderPart == "src/")
        #expect(query?.namePart == "ma")
    }

    @Test func noQueryInsideAWordOrAfterAnotherWord() {
        #expect(MentionQuery(draft: "mail me@host") == nil)
        #expect(MentionQuery(draft: "@a b") == nil)
        #expect(MentionQuery(draft: "") == nil)
    }

    @Test func folderIsRelativeToTheProjectUnlessAbsolute() {
        #expect(MentionQuery(draft: "@src/x")?.folder(in: "/Users/me/app") == "/Users/me/app/src")
        #expect(MentionQuery(draft: "@x")?.folder(in: "/Users/me/app/") == "/Users/me/app")
        #expect(MentionQuery(draft: "@/etc/x")?.folder(in: "/Users/me/app") == "/etc")
        #expect(MentionQuery(draft: "@../x")?.folder(in: "/Users/me/app") == "/Users/me")
    }

    @Test func matchesPutPrefixThenFoldersFirstAndHideDotfiles() {
        let query = MentionQuery(draft: "@ma")
        let found = query?.matches(in: [
            entry("format.swift"), entry("main.swift"), entry("Makefile"), entry("macros", folder: true), entry(".mailrc"),
        ])
        #expect(found?.map(\.name) == ["macros", "main.swift", "Makefile", "format.swift"])
    }

    @Test func dotStartsRevealHiddenEntries() {
        let found = MentionQuery(draft: "@.")?.matches(in: [entry(".env"), entry("a")])
        #expect(found?.map(\.name) == [".env"])
    }

    @Test func noListingMatchesNothing() {
        #expect(MentionQuery(draft: "@a")?.matches(in: nil) == [])
    }

    @Test func pickingReplacesTheMentionAndEscapesSpaces() {
        let query = MentionQuery(draft: "look at @sr")
        #expect(query?.replacing(in: "look at @sr", with: "src", isFolder: true) == "look at @src/")
        #expect(query?.replacing(in: "look at @sr", with: "my file.txt", isFolder: false) == "look at @my\\ file.txt ")
    }
}
