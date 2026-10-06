import CoreGraphics
import Foundation

/// Something a first-run tour can point at.
///
/// A named case rather than a string, because the two ends of a tour cannot see each other: a step
/// says "point at `terminalDeck`" and the view that is the deck says "I am `terminalDeck`". A target
/// nobody reported is absent from the dictionary the steps are filtered against, so a step whose
/// control is not on screen is dropped rather than drawn as a hole over nothing.
public enum TourTarget: String, CaseIterable, Sendable {
    // The Connect screen.
    case connectFirstPairing
    case connectNearby
    case connectRemote
    case connectTrusted
    // The Servers screen.
    case serversOpen
    case serversList
    case serversAdd
    // A shell on a server.
    case shellTabs
    case shellOutput
    // The terminal, on a server and on a Mac alike.
    case terminalDeck
    case terminalInput
    // The remote screen.
    case screenStatus
    case screenDock
    case screenRail
    case screenPointer
}

/// One thing a tour says about one control.
///
/// The words live here rather than at the call site, so that moving an anchor without moving them is
/// awkward, and so every tour's copy is in one file.
public struct TourStep: Identifiable, Equatable, Sendable {
    /// The control this step dims everything else for.
    public let target: TourTarget
    /// What the control is, in a couple of words.
    public let title: String
    /// What it does, in one sentence. Short: it is read at arm's length, over a dimmed app.
    public let detail: String

    /// The target, which is also the identity: two steps for one control would be two rings around
    /// the same thing.
    public var id: TourTarget { target }

    public init(target: TourTarget, title: String, detail: String) {
        self.target = target
        self.title = title
        self.detail = detail
    }
}

/// The five tours, in the order a new person meets the screens they belong to.
///
/// One tour per screen rather than one tour of the app: a tour is a sentence about a control the
/// person is looking at, so it is started when that screen is first reached and remembered per
/// screen by a flag of its own. See ``storageKey``.
public enum Tour: String, CaseIterable, Identifiable, Sendable {
    /// The Connect tab: what is on this network, and what has been paired with before.
    case connect
    /// The Servers tab: the machines added by hand.
    case servers
    /// A shell on a server, once one is open.
    case shell
    /// The terminal itself, on a server and on a Mac alike.
    case terminal
    /// The remote screen, once a session is up.
    case screen

    public var id: Self { self }

    /// Where "has this been seen" is stored.
    ///
    /// Read in both directions: the screen asks whether it owes the tour, and the Settings row that
    /// offers the tips again writes all five. The keys are in ``PreferenceKeys``.
    public var storageKey: String {
        switch self {
        case .connect: PreferenceKeys.hasSeenTourConnect
        case .servers: PreferenceKeys.hasSeenTourServers
        case .shell: PreferenceKeys.hasSeenTourShell
        case .terminal: PreferenceKeys.hasSeenTourTerminal
        case .screen: PreferenceKeys.hasSeenTourScreen
        }
    }

    /// Whether this tour is still owed.
    ///
    /// A missing key reads as `false`, so a fresh install owes all five and nothing has to write a
    /// first-run default: there is no window in which the question is answered wrongly.
    public func isDue(in defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: storageKey)
    }

    /// Marks it as seen, for both of the exits a tour has.
    public func markSeen(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: storageKey)
    }

    /// Puts all five tours back, which is what the Settings row under "Show introduction again"
    /// does. Every tour rather than the one for the screen the row is on: the row is the way back to
    /// something that was skipped, and whoever skipped one is not in a position to say which.
    public static func resetAll(in defaults: UserDefaults = .standard) {
        for tour in allCases { defaults.set(false, forKey: tour.storageKey) }
    }

    /// The steps, in the order they are shown, and every one of them optional in practice: a step
    /// whose control is not on screen is dropped by ``TourRun`` before anything is drawn.
    ///
    /// The order is the order the controls sit on the screen, top to bottom.
    public var steps: [TourStep] {
        switch self {
        case .connect:
            [
                // Drawn only while no Mac has been paired with, which is the state the person
                // reading this tour is in.
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
                // The list of Macs already paired: the answer for somebody who has been here
                // before.
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
                // One step for the whole row, including the switch at its end: the switch is the
                // strip's own accessory and cannot be pointed at on its own, and an anchor written
                // inside the closure that builds it never reaches the tour at all. See ``TabStrip``.
                TourStep(
                    target: .shellTabs,
                    title: String(localized: "Your shells"),
                    detail: String(localized: "Each shell you open gets a tab, and the switch at the end of this row shows the server's own folders. The dot is the shell's state, and the cross on the tab ends it.")
                ),
                // The output is the connection's half of this screen rather than the terminal's: it
                // is what arrived, and the keys and the input line are what to do about it.
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
                // Two steps for one thing, and only ever one of them: the dock holds the controls
                // upright and the rails hold them sideways, and neither exists in the other
                // orientation. The absent one is dropped like any other absent target.
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

/// A tour in progress: the steps that can actually be shown, and which of them is up.
///
/// Built from what is on screen rather than from the script alone: the script is five steps long in
/// the file and two or three long in practice, decided once here rather than asked again on every
/// frame by the view drawing the ring.
///
/// A run is `nil` when nothing in the script is on screen at all (see ``init(tour:appearing:)``).
/// That is not the same as a run that has finished: a tour with no steps to show has not been seen
/// and is not marked as seen.
public struct TourRun: Equatable, Sendable {
    public let tour: Tour
    /// The steps whose controls were on screen when the tour started, in script order.
    public let steps: [TourStep]
    private var index: Int

    /// A run of the steps this screen can actually show, or `nil` when it can show none of them.
    public init?(tour: Tour, appearing: Set<TourTarget>) {
        let available = tour.steps.filter { appearing.contains($0.target) }
        guard !available.isEmpty else { return nil }
        self.tour = tour
        self.steps = available
        self.index = 0
    }

    /// The step being shown, or `nil` once the last one has been passed.
    public var current: TourStep? {
        steps.indices.contains(index) ? steps[index] : nil
    }

    /// How far along, counting from one, for the "2 of 3" on the card.
    public var number: Int {
        min(index + 1, steps.count)
    }

    public var count: Int { steps.count }

    /// Past the last step. The tour is over, but it is the caller that decides whether over means
    /// seen: see ``Tour/markSeen(in:)``.
    public var isFinished: Bool { index >= steps.count }

    /// Moves on one step.
    public mutating func advance() {
        index += 1
    }

    /// Steps forward past anything that has gone from the screen since the run was built.
    ///
    /// The screen changes underneath a tour: a dock put away for the keyboard, a card that only
    /// exists while there is something in it, a panel that closes. A ring drawn round a rectangle
    /// that is no longer there is worse than a step that was never written.
    ///
    /// Forward only, never back: a control that appears late was not there when the person started
    /// reading, and a step that goes backwards reads as the tour losing its place.
    public mutating func skipMissing(appearing: Set<TourTarget>) {
        while let step = current, !appearing.contains(step.target) {
            index += 1
        }
    }
}

/// Whether a reported rectangle is somewhere a person can see it.
///
/// A reported rectangle outlives its source in one direction only. A view that is removed stops
/// reporting, which is what makes an absent control an absent target. A view still there but
/// scrolled off carries on reporting, at coordinates that are valid and nowhere near the display, so
/// a tour anchored to it would draw a ring around a point off the edge of the screen.
///
/// Partial visibility counts, with a floor: a card taller than the viewport is never wholly on
/// screen.
public enum TourVisibility {
    /// How much of a rectangle has to be showing before a step about it is worth showing.
    ///
    /// A thumb's worth: below this the ring is around something the person cannot look at.
    public static let minimumVisible: CGFloat = 44

    /// Half a point of slack, and it is not tidying.
    ///
    /// The comparison below asks whether as much of a control is showing as there is of it, and the
    /// arithmetic that answers is floating point: a 14.3-point chip entirely inside the viewport
    /// comes back as 14.299999999999997 about half the time, and a strict comparison drops a control
    /// that is completely on screen. The switch between a shell and its server's files is that size.
    private static let slack: CGFloat = 0.5

    public static func isOnScreen(_ rect: CGRect, in bounds: CGRect) -> Bool {
        guard !rect.isNull, !rect.isEmpty, rect.width > 0, rect.height > 0 else { return false }
        let overlap = rect.intersection(bounds)
        guard !overlap.isNull, !overlap.isEmpty else { return false }
        // The floor applies to the control's own size as well: a 20-point chip may only ever show
        // 20 points, and asking it for 44 would drop it.
        let wanted = min(min(rect.width, rect.height), minimumVisible)
        return overlap.width + slack >= wanted && overlap.height + slack >= wanted
    }
}
