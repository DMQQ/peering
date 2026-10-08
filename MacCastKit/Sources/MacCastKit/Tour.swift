import CoreGraphics
import Foundation

/// Something a first-run tour can point at. A target nobody reported is absent, so its step is dropped.
public enum TourTarget: String, CaseIterable, Sendable {
    case connectFirstPairing
    case connectNearby
    case connectRemote
    case connectTrusted
    case serversOpen
    case serversList
    case serversAdd
    case shellTabs
    case shellOutput
    case terminalDeck
    case terminalInput
    case screenStatus
    case screenDock
    case screenRail
    case screenPointer
}

public struct TourStep: Identifiable, Equatable, Sendable {
    public let target: TourTarget
    public let title: String
    public let detail: String

    public var id: TourTarget { target }

    public init(target: TourTarget, title: String, detail: String) {
        self.target = target
        self.title = title
        self.detail = detail
    }
}

public enum Tour: String, CaseIterable, Identifiable, Sendable {
    case connect
    case servers
    case shell
    case terminal
    case screen

    public var id: Self { self }

    public var storageKey: String {
        switch self {
        case .connect: PreferenceKeys.hasSeenTourConnect
        case .servers: PreferenceKeys.hasSeenTourServers
        case .shell: PreferenceKeys.hasSeenTourShell
        case .terminal: PreferenceKeys.hasSeenTourTerminal
        case .screen: PreferenceKeys.hasSeenTourScreen
        }
    }

    /// A missing key reads as `false`, so a fresh install owes all five with no first-run default to write.
    public func isDue(in defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: storageKey)
    }

    public func markSeen(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: storageKey)
    }

    /// Every tour, not just this screen's: the row is the way back to anything that was skipped.
    public static func resetAll(in defaults: UserDefaults = .standard) {
        for tour in allCases { defaults.set(false, forKey: tour.storageKey) }
    }

    public var steps: [TourStep] {
        switch self {
        case .connect:
            [
                TourStep(
                    target: .connectFirstPairing,
                    title: String(localized: "First connection"),
                    detail: String(localized: "Both ends run Peering. This card has the Mac download and what pairing asks for.")
                ),
                TourStep(
                    target: .connectNearby,
                    title: String(localized: "Nearby"),
                    detail: String(localized: "A Mac on this network appears here while Peering is running on it. Tap one to connect and pair.")
                ),
                TourStep(
                    target: .connectRemote,
                    title: String(localized: "Another network"),
                    detail: String(localized: "For a Mac that discovery cannot reach: type or scan the device ID it shows.")
                ),
                TourStep(
                    target: .connectTrusted,
                    title: String(localized: "Trusted Macs"),
                    detail: String(localized: "Macs you have paired with live here, and connect without a code.")
                ),
            ]
        case .servers:
            [
                TourStep(
                    target: .serversOpen,
                    title: String(localized: "Still open"),
                    detail: String(localized: "A shell keeps running when you leave it. Come back to it from here.")
                ),
                TourStep(
                    target: .serversList,
                    title: String(localized: "Your servers"),
                    detail: String(localized: "Machines you added by hand. Tap one to open a shell on it.")
                ),
                TourStep(
                    target: .serversAdd,
                    title: String(localized: "Add a server"),
                    detail: String(localized: "A hostname and a key or a password, and it is on this list from then on.")
                ),
            ]
        case .shell:
            [
                // One step for the whole row: an anchor inside the closure that builds the switch never reaches the tour. See ``TabStrip``.
                TourStep(
                    target: .shellTabs,
                    title: String(localized: "Your shells"),
                    detail: String(localized: "Each shell you open gets a tab, and the switch at the end of this row shows the server's own folders. The dot is the shell's state, and the cross on the tab ends it.")
                ),
                TourStep(
                    target: .shellOutput,
                    title: String(localized: "The shell"),
                    detail: String(localized: "Everything the server prints. Tap it to bring the keyboard back, and scroll up to read what has gone by.")
                ),
            ]
        case .terminal:
            [
                TourStep(
                    target: .terminalDeck,
                    title: String(localized: "Keys and commands"),
                    detail: String(localized: "Control keys and the commands you save, so a shell can be driven without typing.")
                ),
                TourStep(
                    target: .terminalInput,
                    title: String(localized: "Typing"),
                    detail: String(localized: "Type here and press Return. The keyboard stays up between commands.")
                ),
            ]
        case .screen:
            [
                TourStep(
                    target: .screenStatus,
                    title: String(localized: "The connection"),
                    detail: String(localized: "How the picture is getting here: which path, how far behind, and how fast. Tap it for the rest.")
                ),
                // Dock or rails, never both; the absent one is dropped like any absent target.
                TourStep(
                    target: .screenDock,
                    title: String(localized: "The controls"),
                    detail: String(localized: "Keys, shortcuts and everything this Mac can show, along the bottom. The chevron opens the rest.")
                ),
                TourStep(
                    target: .screenRail,
                    title: String(localized: "The controls"),
                    detail: String(localized: "Keys, shortcuts and everything this Mac can show, in the two rails at the edges of the picture.")
                ),
                TourStep(
                    target: .screenPointer,
                    title: String(localized: "The pointer"),
                    detail: String(localized: "Drag anywhere in the circle to move the Mac's pointer. The keys beside it send Return and Back.")
                ),
            ]
        }
    }
}

/// `nil` when nothing in the script is on screen. That is not a finished run: the tour is not marked seen.
public struct TourRun: Equatable, Sendable {
    public let tour: Tour
    public let steps: [TourStep]
    private var index: Int

    public init?(tour: Tour, appearing: Set<TourTarget>) {
        let available = tour.steps.filter { appearing.contains($0.target) }
        guard !available.isEmpty else { return nil }
        self.tour = tour
        self.steps = available
        self.index = 0
    }

    public var current: TourStep? {
        steps.indices.contains(index) ? steps[index] : nil
    }

    public var number: Int {
        min(index + 1, steps.count)
    }

    public var count: Int { steps.count }

    /// Over is not seen: the caller decides, see ``Tour/markSeen(in:)``.
    public var isFinished: Bool { index >= steps.count }

    public mutating func advance() {
        index += 1
    }

    /// Steps forward past controls that left the screen since the run was built. Forward only: going back reads as the tour losing its place.
    public mutating func skipMissing(appearing: Set<TourTarget>) {
        while let step = current, !appearing.contains(step.target) {
            index += 1
        }
    }
}

/// A scrolled-off view keeps reporting valid but off-screen coordinates, so visibility is checked. Partial visibility counts, with a floor.
public enum TourVisibility {
    public static let minimumVisible: CGFloat = 44

    /// Slack for floating point: a 14.3-point chip fully on screen compares as 14.299999999999997 about half the time and would be dropped.
    private static let slack: CGFloat = 0.5

    public static func isOnScreen(_ rect: CGRect, in bounds: CGRect) -> Bool {
        guard !rect.isNull, !rect.isEmpty, rect.width > 0, rect.height > 0 else { return false }
        let overlap = rect.intersection(bounds)
        guard !overlap.isNull, !overlap.isEmpty else { return false }
        // The floor applies to the control's own size too: a 20-point chip can never show 44.
        let wanted = min(min(rect.width, rect.height), minimumVisible)
        return overlap.width + slack >= wanted && overlap.height + slack >= wanted
    }
}
