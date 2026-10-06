import XCTest

@testable import MacCastKit

final class AgentDiffTests: XCTestCase {
    func testReplacementShowsBothSidesUnderTheFile() {
        let diff = AgentDiff.replacement(
            old: "const a = 1;",
            new: "const a = 2;",
            path: "/app/src/a.ts"
        )
        XCTAssertEqual(diff, """
        --- /app/src/a.ts
        +++ /app/src/a.ts
        -const a = 1;
        +const a = 2;

        """)
    }

    func testMultiLineReplacement() {
        let diff = AgentDiff.replacement(old: "one\ntwo", new: "one\nthree", path: nil)
        XCTAssertEqual(diff, "-one\n-two\n+one\n+three\n")
    }

    /// A trailing newline is how a file ends, not an empty line in the change.
    func testTrailingNewlineIsNotALine() {
        let diff = AgentDiff.replacement(old: "a\n", new: "b\n", path: nil)
        XCTAssertEqual(diff, "-a\n+b\n")
    }

    func testCreationWithNoOldSide() {
        let diff = AgentDiff.replacement(old: "", new: "hello", path: nil)
        XCTAssertEqual(diff, "+hello\n")
    }

    func testLongChangeIsCutAndSaysSo() {
        let old = (1...2_000).map { "line \($0)" }.joined(separator: "\n")
        let diff = AgentDiff.replacement(old: old, new: "", path: nil, limit: 512)
        XCTAssertLessThanOrEqual(diff.utf8.count, 600)
        XCTAssertTrue(diff.hasSuffix("(the rest of this change is not shown)\n"), diff.suffix(60).description)
    }
}
