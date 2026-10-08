import Foundation
import RemoteCore

/// Which changed files a commit takes. Files the filter hides start out and stay out until the user shows and ticks them.
public struct AgentCommitSelection: Equatable, Sendable {
    private var unticked: Set<String> = []
    private var tickedHidden: Set<String> = []

    public init() {}

    public func isChosen(_ file: AgentChangedFile, hidden: Bool) -> Bool {
        hidden ? tickedHidden.contains(file.path) : !unticked.contains(file.path)
    }

    public mutating func toggle(_ file: AgentChangedFile, hidden: Bool) {
        if hidden {
            if !tickedHidden.insert(file.path).inserted { tickedHidden.remove(file.path) }
        } else {
            if !unticked.insert(file.path).inserted { unticked.remove(file.path) }
        }
    }

    public mutating func reset() { self = AgentCommitSelection() }

    /// The files to commit, in the report's order. `isHidden` is the filter's verdict for a file.
    public func chosen(from files: [AgentChangedFile], isHidden: (AgentChangedFile) -> Bool) -> [AgentChangedFile] {
        files.filter { isChosen($0, hidden: isHidden($0)) }
    }
}
