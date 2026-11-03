import Foundation

/// The phrases of ``AgentTurnRecap/line(words:)``, supplied by the app so they follow its language; English for tests.
public struct AgentRecapWords: Sendable {
    public var changedFiles: @Sendable (_ count: Int) -> String
    public var testsPassed: String
    public var testsFailed: String
    public var waitingToPush: String
    public var join: @Sendable (_ parts: [String]) -> String

    public init(
        changedFiles: @escaping @Sendable (Int) -> String,
        testsPassed: String,
        testsFailed: String,
        waitingToPush: String,
        join: @escaping @Sendable ([String]) -> String = AgentRecapWords.sentence
    ) {
        self.changedFiles = changedFiles
        self.testsPassed = testsPassed
        self.testsFailed = testsFailed
        self.waitingToPush = waitingToPush
        self.join = join
    }

    /// Parts after the first are lower case, so a line that starts with one of them needs its first letter raised.
    @Sendable public static func sentence(_ parts: [String]) -> String {
        let joined = parts.joined(separator: ", ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    public static let english = AgentRecapWords(
        changedFiles: { $0 == 1 ? "Changed 1 file" : "Changed \($0) files" },
        testsPassed: "tests passed",
        testsFailed: "tests failed",
        waitingToPush: "waiting to push"
    )
}
