import Foundation

/// The decisions behind moving between the mode picker and the modes, kept out of the view so they can be tested.
public enum SessionModeFlow {
    /// Where the navigation stack rests: the picker alone, the Mac's picture (and Remote's dock) pushed over it, or the Agents hub pushed over it.
    public enum Target: Equatable, Sendable {
        case picker
        case surface
        case hub
    }

    /// What a page on the stack is, without what it holds: the stack's pages are app types, and the rules about them are not.
    public enum PageKind: Equatable, Sendable {
        case screen
        case hub
        case step
    }

    public enum Entry: Equatable, Sendable {
        case reapply(SessionMode)
        case open(SessionMode)
        case ask
    }

    public static func target(for mode: SessionMode) -> Target {
        mode == .workspace ? .hub : .surface
    }

    /// The stack only moves when the mode asks for a different place than it is in, so applying a mode twice is harmless.
    public static func retarget(entering mode: SessionMode, from current: Target) -> Target? {
        let wanted = target(for: mode)
        return wanted == current ? nil : wanted
    }

    /// What to do when a session becomes ready.
    public static func entry(
        modeResolved: Bool,
        current: SessionMode,
        remembered: SessionModeMemory.Decision
    ) -> Entry {
        if modeResolved { return .reapply(current) }
        switch remembered {
        case .open(let mode): return .open(mode)
        case .ask: return .ask
        }
    }

    /// The picker is the stack's root once a mode is resolved, or while one is being asked for. Before that the root is the connecting picture.
    public static func rootIsPicker(modeResolved: Bool, asking: Bool) -> Bool {
        modeResolved || asking
    }

    /// What the stack is resting on, from its first page. A hub pushed over the picture is still resting on the picture.
    public static func target(firstPage: PageKind?) -> Target {
        switch firstPage {
        case nil: .picker
        case .screen: .surface
        case .hub, .step: .hub
        }
    }

    /// How many pages lie under the hub: the picture it was opened over, or none. A stack with no hub is all base.
    public static func basePageCount(of pages: [PageKind]) -> Int {
        pages.firstIndex(of: .hub) ?? pages.count
    }
}
