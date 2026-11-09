import Foundation

/// Turns the commands a person sends, with the time each arrived, into the steps of a macro.
public struct MacroRecorder: Sendable {
    /// Why the recording stopped taking steps.
    public enum Stop: Equatable, Sendable {
        case stepLimit
        case durationLimit
    }

    /// Pointer moves closer together than this are one move: the phone sends one per frame, and replaying every one would add nothing a viewer can see.
    public static let moveMergeMilliseconds = 30

    public private(set) var steps: [MacroStep] = []
    public private(set) var stopped: Stop?
    private var lastAt: TimeInterval?
    private var totalMilliseconds = 0

    public init() {}

    /// `at` is monotonic seconds. A command a macro cannot hold is ignored, so a recording made across a clipboard copy or a quality change still plays.
    public mutating func record(_ command: RemoteCommand, at time: TimeInterval) {
        guard stopped == nil, MacroLimits.accepts(command) else { return }
        let gap = lastAt.map { max(0, Int(((time - $0) * 1000).rounded())) } ?? 0
        let delay = min(gap, MacroLimits.maxStepDelayMilliseconds)

        if case .mouseMove = command, let last = steps.last, case .mouseMove = last.command, delay < Self.moveMergeMilliseconds {
            steps[steps.count - 1].command = command
            lastAt = time
            return
        }
        if steps.count >= MacroLimits.maxSteps {
            stopped = .stepLimit
            return
        }
        if Double(totalMilliseconds + delay) / 1000 > MacroLimits.maxDurationSeconds {
            stopped = .durationLimit
            return
        }
        steps.append(MacroStep(delayMilliseconds: delay, command: command))
        totalMilliseconds += delay
        lastAt = time
    }

    /// The macro so far, with the first step starting at once.
    public func macro(named name: String, createdAt: Date = Date()) -> Macro {
        Macro(name: name, steps: steps, createdAt: createdAt)
    }
}
