import Foundation

/// A sequence of input the Mac replays by itself, so the phone does not have to be connected.
public struct Macro: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var steps: [MacroStep]
    /// Nil means the macro runs only when asked.
    public var schedule: AgentRoutineSchedule?
    public var isEnabled: Bool
    public var createdAt: Date
    /// Kept by the Mac: whatever the phone sends here is ignored.
    public var lastRun: MacroRun?

    public init(
        id: UUID = UUID(),
        name: String,
        steps: [MacroStep],
        schedule: AgentRoutineSchedule? = nil,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        lastRun: MacroRun? = nil
    ) {
        self.id = id
        self.name = name
        self.steps = steps
        self.schedule = schedule
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.lastRun = lastRun
    }

    /// Every step's wait added up: how long a run takes without counting the time the commands themselves need.
    public var duration: TimeInterval {
        Double(steps.reduce(0) { $0 + $1.delayMilliseconds }) / 1000
    }
}

public struct MacroStep: Codable, Equatable, Sendable {
    /// Time to wait after the previous step.
    public var delayMilliseconds: Int
    public var command: RemoteCommand

    public init(delayMilliseconds: Int, command: RemoteCommand) {
        self.delayMilliseconds = delayMilliseconds
        self.command = command
    }
}

public struct MacroRun: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Equatable, Sendable {
        case running
        case succeeded
        /// Ended early because a person used the Mac, or pressed stop.
        case aborted
        /// Never started; ``MacroRun/detail`` says why.
        case skipped
        case failed
    }

    public var startedAt: Date
    public var outcome: Outcome
    public var detail: String?

    public init(startedAt: Date, outcome: Outcome, detail: String? = nil) {
        self.startedAt = startedAt
        self.outcome = outcome
        self.detail = detail
    }
}

/// What a macro may hold and how big it may grow. The Mac enforces these on whatever the phone sends, so a hand-built macro is held to them too.
public enum MacroLimits {
    public static let maxSteps = 4_000
    public static let maxDurationSeconds: TimeInterval = 300
    /// A pause longer than this while recording is stored as this long: a macro is not a timer.
    public static let maxStepDelayMilliseconds = 5_000
    public static let maxTextCharacters = 2_000
    public static let maxNameCharacters = 60
    public static let macrosPerClient = 30

    /// Commands that are input to the Mac's own screen. A command that moves the stream or the clipboard is the session's, not the macro's, and one that locks, hides or adds a display would act on the Mac in ways a replay cannot undo.
    public static func accepts(_ command: RemoteCommand) -> Bool {
        switch command {
        case .mouseMove, .mouseDown, .mouseUp, .scroll, .keyDown, .keyUp, .switchSpace, .switchToSpace,
             .launchApplication, .openNewWindow:
            true
        case .textInput(let text):
            text.count <= maxTextCharacters
        case .joystickMove, .setCaptureSource, .setStreamQuality, .setVideoEnabled, .refreshSpacePreviews,
             .requestKeyframe, .refreshSourceThumbnails, .watchSourceThumbnails, .setPrivacyMode, .lockScreen,
             .requestClipboard, .pushClipboard, .pushClipboardImage, .reportDeviceOrientation, .addVirtualDisplay,
             .removeVirtualDisplay, .renameVirtualDisplay, .performWindowAction:
            false
        }
    }

    /// Why a macro cannot be kept, or nil when it can.
    public static func problem(with macro: Macro) -> String? {
        if macro.steps.isEmpty { return "The macro has no steps." }
        if macro.steps.count > maxSteps { return "The macro has more than \(maxSteps) steps." }
        if macro.name.trimmingCharacters(in: .whitespaces).isEmpty || macro.name.count > maxNameCharacters {
            return "The macro needs a name of up to \(maxNameCharacters) characters."
        }
        if macro.steps.contains(where: { $0.delayMilliseconds < 0 || $0.delayMilliseconds > maxStepDelayMilliseconds }) {
            return "A step waits for longer than \(maxStepDelayMilliseconds / 1000) seconds."
        }
        if macro.duration > maxDurationSeconds { return "The macro runs for longer than \(Int(maxDurationSeconds)) seconds." }
        if !macro.steps.allSatisfy({ accepts($0.command) }) { return "The macro holds a command that a macro cannot run." }
        return nil
    }
}
