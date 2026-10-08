import Testing
@testable import MacCastKit

struct AgentGitDiffParsingTests {
    private func block(_ path: String, eol: String = "\n") -> String {
        ["diff --git a/\(path) b/\(path)", "--- a/\(path)", "+++ b/\(path)", "@@ -1 +1 @@", "-old", "+new", ""]
            .joined(separator: eol)
    }

    @Test func aFileWithCRLFLinesDoesNotHideTheNextFile() {
        let files = AgentGitDiff.files(in: block("first.txt", eol: "\r\n") + block("second.txt"))
        #expect(files.map(\.path) == ["first.txt", "second.txt"])
    }

    @Test func aQuotedNameIsListedUnderItsRealPath() {
        let patch = """
        diff --git "a/x\\"y" "b/x\\"y"
        --- "a/x\\"y"
        +++ "b/x\\"y"
        @@ -1 +1 @@
        -old
        +new

        """
        #expect(AgentGitDiff.files(in: patch).map(\.path) == ["x\"y"])
    }

    @Test func octalEscapesDecodeToUTF8() {
        #expect(AgentGitDiff.unquoted("\"caf\\303\\251\"") == "café")
    }

    @Test func aDeletedFileIsNotNamedAfterALaterFilesHeader() {
        let deleted = """
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye

        """
        let files = AgentGitDiff.files(in: deleted + block("kept.txt"))
        #expect(files.map(\.path) == ["gone.txt", "kept.txt"])
        #expect(files.first?.kind == .deleted)
    }
}
