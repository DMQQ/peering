import CoreGraphics
import Foundation

/// Something a first-run tour can point at.
///
/// A named case rather than a string or a key path, because the two ends of a tour have to agree
/// about which control is meant and neither of them can see the other. A step says "point at
/// `terminalDeck`"; the view that *is* the deck says "I am `terminalDeck`", and the two are the
/// same declaration. That is also what makes the missing case work: a target nobody reported is
/// simply not in the dictionary the steps are filtered against, so a step whose control is not on
/// screen is dropped rather than drawn as a hole over nothing.
///
/// The whole of the app's list, rather than one enum per screen, and the reason is the dictionary
/// the anchors are collected in. One key type, one preference key, one mechanism; a per-screen
/// enum would be a per-screen anchor key and the same twenty lines written five times.
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
/// The title and the sentence are written here rather than at the call site, because a step and
/// the control it describes are one fact: moving the anchor to a different control without moving
/// the words is the failure this type makes awkward, and every tour's copy is then in one file
/// that can be read end to end rather than scattered through five screens.
public struct TourStep: Identifiable, Equatable, Sendable {
    /// The control this step dims everything else for.
    public let target: TourTarget
    /// What the control is, in a couple of words.
    public let title: String
    /// What it does, in one sentence. Short: it is read at arm's length, over a dimmed app.
    public let detail: String

    /// The target, which is also the identity: two steps for one control would be two rings around
    /// the same thing, and nothing in the app wants that.
    public var id: TourTarget { target }

    public init(target: TourTarget, title: String, detail: String) {
        self.target = target
        self.title = title
        self.detail = detail
    }
}

/// The five tours, in the order a new person meets the screens they belong to.
///
/// **One tour per screen rather than one tour of the app**, and that is the decision the whole
/// feature rests on. A tour is a sentence about a control the person is looking at; the second
/// screen of a five-screen flow is a screen they have not reached, and its controls are behind a
/// tap they have not made. So a tour is owed by a screen, is started when that screen is first
/// reached, and is remembered per screen by a flag of its own. See ``storageKey``.
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
    /// Read in both directions by the app: the screen asks it to know whether it owes the tour,
    /// and the Settings row that offers the tips again writes all five. The keys themselves are in
    /// ``PreferenceKeys`` for the reason recorded there.
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
    /// first-run default. That is the same shape the app's other "has been seen" flag uses, and it
    /// is the one that cannot be raced: there is no window between the app starting and a default
    /// being written in which the question is answered wrongly.
    public func isDue(in defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: storageKey)
    }

    /// Marks it as seen, for both of the exits a tour has.
    public func markSeen(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: storageKey)
    }

    /// Puts all five tours back, which is what the Settings row under "Show introduction again"
    /// does.
    ///
    /// Every tour rather than the one for the screen the row is on: the row is the way back to
    /// something that was skipped, and whoever skipped one is not in a position to say which.
    public static func resetAll(in defaults: UserDefaults = .standard) {
        for tour in allCases { defaults.set(false, forKey: tour.storageKey) }
    }

    /// The steps, in the order they are shown, and every one of them optional in practice: a step
    /// whose control is not on screen is dropped by ``TourRun`` before anything is drawn.
    ///
    /// The order is the order the controls sit on the screen, top to bottom, which is the order
    /// the eye already reads them in. A tour that jumped about would have to be followed rather
    /// than read.
    public var steps: [TourStep] {
        switch self {
        case .connect:
            [
                // Drawn only while no Mac has been paired with, which is the state the person
                // reading this tour is in. It goes once there is one, so the step goes with it.
                TourStep(
                    target: .connectFirstPairing,
                    title: "First connection",
                    detail: "Both ends run Peering. This card has the Mac download and what pairing asks for."
                ),
                TourStep(
                    target: .connectNearby,
                    title: "Nearby",
                    detail: "A Mac on this network appears here while Peering is running on it. Tap one to connect and pair."
                ),
                TourStep(
                    target: .connectRemote,
                    title: "Another network",
                    detail: "For a Mac that discovery cannot reach: type or scan the device ID it shows."
                ),
                // The list of Macs already paired, which is the one part of the card that is
                // usually below the fold: it is the answer for somebody who has been here before,
                // and by then the card above it has gone and this one is on the screen.
                TourStep(
                    target: .connectTrusted,
                    title: "Trusted Macs",
                    detail: "Macs you have paired with live here, and connect without a code."
                ),
            ]
        case .servers:
            [
                TourStep(
                    target: .serversOpen,
                    title: "Still open",
                    detail: "A shell keeps running when you leave it. Come back to it from here."
                ),
                TourStep(
                    target: .serversList,
                    title: "Your servers",
                    detail: "Machines you added by hand. Tap one to open a shell on it."
                ),
                TourStep(
                    target: .serversAdd,
                    title: "Add a server",
                    detail: "A hostname and a key or a password, and it is on this list from then on."
                ),
            ]
        case .shell:
            [
                // One step for the whole row, including the switch at its end, because the switch
                // cannot be pointed at on its own: it is the strip's own accessory, and an anchor
                // written inside the closure that builds it never reaches the tour at all: the
                // step was dropped as silently as if the control were off screen, with the control
                // drawn in front of it. The row lights up with the switch inside the light, and the
                // sentence names both halves. See ``TabStrip``.
                TourStep(
                    target: .shellTabs,
                    title: "Your shells",
                    detail: "Each shell you open gets a tab, and the switch at the end of this row shows the server's own folders. The dot is the shell's state, and the cross on the tab ends it."
                ),
                // The output is the *connection's* half of this screen rather than the terminal's:
                // it is what arrived, and the row of keys and the line that types are what to do
                // about it. Splitting them that way is also what keeps both tours on this screen at
                // two steps, which is the length a coach mark survives being read at.
                TourStep(
                    target: .shellOutput,
                    title: "The shell",
                    detail: "Everything the server prints. Tap it to bring the keyboard back, and scroll up to read what has gone by."
                ),
            ]
        case .terminal:
            [
                TourStep(
                    target: .terminalDeck,
                    title: "Keys and commands",
                    detail: "Control keys and the commands you save, so a shell can be driven without typing."
                ),
                TourStep(
                    target: .terminalInput,
                    title: "Typing",
                    detail: "Type here and press Return. The keyboard stays up between commands."
                ),
            ]
        case .screen:
            [
                TourStep(
                    target: .screenStatus,
                    title: "The connection",
                    detail: "How the picture is getting here: which path, how far behind, and how fast. Tap it for the rest."
                ),
                // Two steps for one thing, and only ever one of them: the dock is where the
                // controls are held upright and the rails are where they are held sideways, and
                // neither exists in the other orientation. Whichever is not on screen is dropped
                // like any other absent target, so the tour says the same thing in both.
                TourStep(
                    target: .screenDock,
                    title: "The controls",
                    detail: "Keys, shortcuts and everything this Mac can show, along the bottom. The chevron opens the rest."
                ),
                TourStep(
                    target: .screenRail,
                    title: "The controls",
                    detail: "Keys, shortcuts and everything this Mac can show, in the two rails at the edges of the picture."
                ),
                TourStep(
                    target: .screenPointer,
                    title: "The pointer",
                    detail: "Drag anywhere in the circle to move the Mac's pointer. The keys beside it send Return and Back."
                ),
            ]
        }
    }
}

/// A tour in progress: the steps that can actually be shown, and which of them is up.
///
/// Built from what is on screen rather than from the script alone, and that is the whole of the
/// type. The script is five steps long in the file and two or three steps long in practice; the
/// difference is which of the controls the screen has, and it is decided once, here, rather than
/// asked again on every frame by the view drawing the ring.
///
/// A run is `nil` when nothing in the script is on screen at all (see ``init(tour:appearing:)``).
/// That is not the same as a run that has finished: a tour with no steps to show has not been
/// seen and is not marked as seen, which is what keeps the Connect screen's first-run tips owed by
/// somebody who reached the screen before the cards had arrived.
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

    /// Past the last step. The tour is over, but it is the *caller* that decides whether over
    /// means seen: see ``Tour/markSeen(in:)`` and the view that reads this.
    public var isFinished: Bool { index >= steps.count }

    /// Moves on one step.
    public mutating func advance() {
        index += 1
    }

    /// Steps forward past anything that has gone from the screen since the run was built.
    ///
    /// **The screen changes underneath a tour, and the tour has to survive it.** A dock put away
    /// for the keyboard, a card that only exists while there is something in it, a panel that
    /// closes: any of those removes the control the current step is about, and a ring drawn round
    /// a rectangle that is no longer there is worse than a step that was never written. So the run
    /// walks forward to the next step whose control is still reported.
    ///
    /// Forward only, and never back. A control that appears late was not there when the person
    /// started reading, and a step that goes backwards to a control the person has already passed
    /// reads as the tour losing its place.
    public mutating func skipMissing(appearing: Set<TourTarget>) {
        while let step = current, !appearing.contains(step.target) {
            index += 1
        }
    }
}

/// Whether a reported rectangle is somewhere a person can see it.
///
/// **A reported rectangle outlives the place it was reported from in one direction only.**
/// A view that is removed stops reporting, which is what makes an absent control an absent target.
/// A view that is still there but *scrolled off* the screen carries on reporting, at coordinates
/// that are perfectly valid and nowhere near the display, so a tour anchored to it would dim the
/// app and draw a ring around a point off the edge of the screen. This is the second half of the
/// rule that a step is skipped rather than drawn over nothing.
///
/// Partial visibility counts, with a floor: a card taller than the viewport is never wholly on
/// screen, and a step that demanded that would be a step that never ran. A control one line of
/// which is showing is not a control that can be read, which is what the floor is for.
public enum TourVisibility {
    /// How much of a rectangle has to be showing before a step about it is worth showing.
    ///
    /// A thumb's worth: below this the ring is around something the person cannot look at, and the
    /// sentence beside it is describing a control they cannot see.
    public static let minimumVisible: CGFloat = 44

    /// A hair of slack, and it is not tidying.
    ///
    /// The comparison below asks a control whether as much of it is showing as there is of it, and
    /// the arithmetic that answers is floating point: a 14.3-point chip entirely inside the
    /// viewport comes back as 14.299999999999997 about half the time, and a strict comparison drops
    /// a control that is *completely* on screen over four hundred-billionths of a point. That is not
    /// a hypothetical: the switch between a shell and its server's files is exactly that size, and
    /// its step was silently dropped for it. Half a point, which is under a pixel on every screen
    /// this runs on and far under the smallest distance a person can aim at.
    private static let slack: CGFloat = 0.5

    public static func isOnScreen(_ rect: CGRect, in bounds: CGRect) -> Bool {
        guard !rect.isNull, !rect.isEmpty, rect.width > 0, rect.height > 0 else { return false }
        let overlap = rect.intersection(bounds)
        guard !overlap.isNull, !overlap.isEmpty else { return false }
        // The floor applies to the control's own size as well: a 20-point chip may only ever show
        // 20 points, and asking it for 44 would drop it from a tour that has a step for it.
        let wanted = min(min(rect.width, rect.height), minimumVisible)
        return overlap.width + slack >= wanted && overlap.height + slack >= wanted
    }
}
