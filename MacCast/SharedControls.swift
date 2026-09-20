import MacCastKit
import SwiftUI

/// The card-and-row vocabulary the app's settings-shaped screens are built from.
///
/// These started life as private methods on the Settings tab, which was right while there was one
/// settings-shaped screen. There are three now — Settings, a past session's detail, and whatever the
/// SSH tab grows — and the choice was between copying them and lifting them. Copying is what this
/// file exists to stop: the app already has one surface style living in two places (`iconTile`, whose
/// body is written out again inside `recentRow`), and the two copies had drifted before anything was
/// even built on them.
///
/// The shape is deliberate and worth keeping. `row` takes a *label and a control* rather than a
/// `Toggle` or a `Picker`, because a menu picker in a plain stack is a control that names itself on
/// the left and shows its value as part of the button — which reads as three odd rows with a word
/// floating in the middle of them. Split apart, a picker and a switch are the same shape, and every
/// row on every one of these screens starts with a glyph and a name.
enum Controls {
    /// The heading on a card of rows: a glyph and a name, in the sentence case the Connect and
    /// Sessions tabs use.
    ///
    /// Not the same thing as ``SectionLabel``, which is the uppercase one the Settings tab uses,
    /// and the difference is worth knowing about rather than tidying away: Settings is a list of
    /// small labelled questions and its headings are labels *of* the rows under them, while these
    /// screens are made of objects — a Mac, a server, a session — and their cards are named after
    /// the objects. It lived as a private function on the Connect screen until the Servers tab
    /// grew cards of the same kind, which is the point at which a shape stops being accidental.
    static func sectionLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.2)
        }
        .foregroundStyle(.secondary)
    }

    /// A titled card of rows, with an optional sentence underneath in the smallest type.
    @ViewBuilder
    static func card<Content: View>(
        _ title: String,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title)
            content()
                .font(.subheadline)
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .cardSurface()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One row: the glyph, the name of the setting, and its control.
    static func row<Control: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 11) {
            icon(systemImage)

            Text(title)
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 10)

            control()
        }
        .padding(.vertical, 2)
    }

    static func toggle(
        _ title: String,
        systemImage: String,
        isOn: Binding<Bool>
    ) -> some View {
        row(title, systemImage: systemImage) {
            // The title goes on the `Toggle` and is hidden rather than dropped, so the switch
            // still has a name of its own to be read out by.
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .tint(ColorPalette.accent)
        }
    }

    /// A menu picker wearing a row's label rather than its own.
    ///
    /// The tint is what the value is printed in. Left alone it is the accent, which in this app
    /// means "this is on" and nothing else — a picked value is not a state, it is a setting's
    /// current answer, so it is printed in the same white at reduced weight as every other value.
    static func picker<Value: Hashable>(
        _ title: String,
        systemImage: String,
        selection: Binding<Value>,
        @ViewBuilder options: () -> some View
    ) -> some View {
        row(title, systemImage: systemImage) {
            Picker(title, selection: selection) { options() }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(.white.opacity(0.72))
                .font(.subheadline)
        }
    }

    /// The small tile a row's glyph sits in — a third of the size of ``IconTile``, which is the same
    /// object for a whole row rather than for the label of one.
    static func icon(_ symbol: String, tint: Color = ColorPalette.ink) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(0.14))
            }
    }

    /// Between two rows, and never after the last one — a rule under the bottom row of a card is a
    /// line with nothing on the other side of it.
    static var divider: some View {
        Divider().overlay(.white.opacity(0.07))
    }
}

// MARK: - Locked controls

/// The plan a control needs, drawn on that control rather than beside it or in its place.
///
/// **The badge, not the gate.** A capsule saying RELAY, PLUS or PRO is the same word the cards and
/// the sheet use, so the badge, the tap and the purchase all name one thing: what is drawn here is
/// the name of the plan, and what unlocks the control it is drawn on.
///
/// It used to be the gate as well, worn where the control would have been, which is how a row
/// reading "Add a server" came to end in a badge with the plus taken away. ``PlanLocked`` records
/// why that was wrong twice over; this type is what is left of it, and the only thing it decides
/// now is how a plan's name is drawn on the control that belongs to it.
///
/// **Two drawings of one word, because the badge has two jobs.** ``Form/control`` is the badge as a
/// peer of the control: drawn to roughly the control's height, so it lands at the same optical
/// weight as the row around it and a column of them still lines up. ``Form/corner`` is the badge as
/// a mark on a control that has a frame of its own, pinned to its top-trailing corner at a fraction
/// of that height. The second one exists because the first took the layout's width everywhere it
/// appeared, and the layout paid for it by moving what was next to the control: at the deck's
/// 46-point chips the badge beside the chip was 53 points wide with 8 points of spacing after it,
/// so a plan changing under the user's thumb reshuffled a row of keys they were reaching into.
///
/// Hidden from VoiceOver in both forms, because the control under the badge carries the whole
/// sentence. Read on its own this is a plan name with no verb.
struct PlanLock: View {
    /// The plan that unlocks it. The badge is its name, because the same word has to appear here,
    /// on the card that sells it and in the sheet this opens.
    let capability: PlanCapability
    /// Roughly the size of the control it belongs to: a row's switch is about 30 across, a toolbar
    /// glyph less, the deck's chips more.
    ///
    /// The ``Form/control`` badge is drawn to this height and no wider than its own text needs. The
    /// ``Form/corner`` mark reads it only at the top of that range: it is the same size at every
    /// gate in the app, grown by a point and a half for the deck's chips, which are large enough
    /// that a mark the size of the one on a toolbar glyph would read as a speck on them.
    var diameter: CGFloat = 30
    /// Which of the two drawings this is. See ``Form``.
    var form: Form = .control

    /// The two shapes the same word is drawn in.
    ///
    /// Same tint, same capsule and the same accessibility in both: the difference is what each one
    /// is standing on, and it is a difference of size rather than of meaning. One of them is a peer
    /// of the control and takes room in the layout for itself; the other is a mark on the control
    /// and takes none.
    enum Form {
        /// Drawn to the control's own size, for a badge standing at the end of it.
        case control
        /// A small fixed mark, for a control's top-trailing corner.
        case corner
    }

    var body: some View {
        switch form {
        case .control:
            capsule(
                typeSize: max(9, diameter * 0.32),
                tracking: 0.5,
                horizontal: diameter * 0.3,
                vertical: diameter * 0.17
            )
        case .corner:
            capsule(typeSize: cornerTypeSize, tracking: 0.4, horizontal: 4, vertical: 1.5)
        }
    }

    /// How large the corner mark's name is printed.
    ///
    /// Between eight and a half and ten points whatever it is sitting on, which is small enough to
    /// read as a mark rather than as a second control and large enough to still be a word: the
    /// widest name in the map, RELAY, is under 30 points of text at this size. The range is narrow
    /// on purpose and the ceiling is the half of it that does any work: the deck's chips are more
    /// than twice the size of a toolbar glyph, and a mark that ignored that would read as a speck
    /// on them, so they are the one site that takes the larger size.
    private var cornerTypeSize: CGFloat { max(8.5, min(10, diameter * 0.25)) }

    /// The plan's name in its capsule, at whatever size the form asks for.
    ///
    /// `fixedSize` is not tidying, it is the one thing that keeps this legible on the smallest
    /// control it is drawn on: an overlay is proposed the size of the control underneath it, and a
    /// toolbar glyph is narrower than the word PLUS, so without it the badge comes apart into two
    /// lines on exactly the controls with the least room to spare.
    private func capsule(
        typeSize: CGFloat,
        tracking: CGFloat,
        horizontal: CGFloat,
        vertical: CGFloat
    ) -> some View {
        Text(capability.minimumPlan.badge)
            .font(.system(size: typeSize, weight: .bold))
            .tracking(tracking)
            .foregroundStyle(ColorPalette.accent)
            .fixedSize()
            .padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .background(ColorPalette.accent.opacity(0.18), in: Capsule())
            // Hidden because the button around it carries the whole sentence. Read on its own this
            // is a plan name with no verb, and what a VoiceOver user needs is "Macros, locked".
            .accessibilityHidden(true)
    }
}

/// A gated control: the control itself, wearing the plan's name on its corner when the plan does
/// not include it.
///
/// **The control is drawn as itself, in its own shape and with its own glyph, dimmed, with a small
/// plan-name badge on its top-trailing corner. Tapping it opens the paywall. Never a padlock, never
/// a badge in the control's place.** That is the owner's rule for every gate in the app, and it is
/// the third attempt: the first two are worth recording, because both were argued for at the time.
///
/// The first drew a padlock the size of the control it replaced. A padlock is the glyph the system
/// uses for a passcode, so it answers "why did that not work" with a word about security rather
/// than a word about money, and it answers "what was that button" with nothing at all.
///
/// The second kept the words and swapped the glyph, so a row saying "Add a server" ended in a
/// padlock where the plus had been. The owner rejected that twice, and the reason is the one the
/// first attempt had already given: a user looking at "Add a server" with the plus taken away
/// cannot tell what the button does. Words alone do not carry a control whose icon has been
/// replaced, which makes the swap the same mistake in a smaller place rather than a fix.
///
/// So the label is the real control, written once, drawn exactly as the unlocked branch draws it,
/// and the locked state is that same drawing dimmed and inert inside a button that opens the plans.
/// Nothing is renamed, nothing is hidden and nothing is swapped: what the plan adds to the sentence
/// is the badge, which is why the badge is drawn *on* the control and never in its place.
///
/// **The badge's position was the third thing to be wrong here, and in the smallest way.** Beside
/// the control was the owner's own instruction, and it was right about everything except the width:
/// a locked control took its own width, plus 8 points of spacing, plus a capsule carrying a word,
/// and the layout underneath moved to pay for it. On the settings rows that was 53 points out of a
/// card's width with a switch's label pushed in from the edge of it; at the deck's chips it was a
/// row of keys that reshuffled when a plan changed under a thumb. A locked control should cost the
/// layout exactly what the unlocked one costs, so the badge hangs off the corner instead and the
/// layout is the unlocked layout. The controls with something already at the end of them, a row
/// with a chevron, still wear it over that end, which costs nothing either: see ``BadgePlacement``
/// for which control gets which.
///
/// **One type rather than the same three lines at each gate.** Every one of these has to do two
/// things that are easy to get wrong in a way nobody notices: open the paywall at the *feature*
/// door rather than the generic one, so the sheet says what was pressed, and say out loud what was
/// locked, because a VoiceOver user gets no picture of a badge. Written per site, one of them would
/// eventually open the generic door, and the sheet would then explain the relay to somebody who
/// tapped the sound switch.
///
/// The label is the capability's own name rather than a second string per site: the row and the
/// sheet name the same feature the same way, because they are the same value.
struct PlanLocked<Label: View>: View {
    let capability: PlanCapability
    /// What the control is called, where it differs from the capability's own name: a toolbar
    /// glyph has no row around it to say what it is, and "New shell, locked" is what the user
    /// pressed where "Several shells at once, locked" is what the app sells.
    var title: String?
    /// Where the badge goes, which follows from what the control is. See ``BadgePlacement``.
    ///
    /// ``BadgePlacement/corner`` is the default because it is the only placement that fits every
    /// control: it takes nothing from the layout, so a control that has a frame of its own is the
    /// same size locked as it is unlocked, and nothing around it moves when a plan changes.
    var placement: BadgePlacement = .corner
    /// Roughly the size of the control. The badge takes its own scale from it, which is a
    /// proportional one beside a control and a nearly fixed one on its corner: see the parameter on
    /// ``PlanLock``.
    var diameter: CGFloat = 30
    /// Whether the control is live, where that is not the same question as whether the plan
    /// includes the capability.
    ///
    /// `nil` means ask the map, which is what every gate in the app does and what this type exists
    /// to centralise. The three sites that pass a value are all about a *first* thing being free on
    /// every plan: the Mac terminal's `+`, which is only the paid thing once there is a shell to be
    /// concurrent with, and the two pairing rows, where the first Mac is free and the second one is
    /// not. Asking the map alone at those sites would take away the free one, which is the failure
    /// this parameter is here to prevent.
    var isIncluded: Bool?
    @ViewBuilder var label: () -> Label

    @Environment(SessionModel.self) private var model

    /// How far a gated control is taken down.
    ///
    /// Not `.disabled()`, which would grey the control out with a system opacity and, worse, would
    /// make the *inner* control the thing that answers a press: the label has to stay legible and
    /// the tap has to reach the button around it. This is far enough that nobody mistakes it for
    /// live and not so far that the glyph and the words stop saying what the control is, which is
    /// the whole reason it is still drawn.
    private static var dim: Double { 0.6 }

    var body: some View {
        if isIncluded ?? model.storeManager.access.includes(capability) {
            label()
        } else {
            Button {
                model.paywallReason = .feature(capability)
            } label: {
                locked
            }
            .buttonStyle(.plain)
            // One element, not two. Without this a VoiceOver user would find a control that looks
            // and reads as live and does nothing when it is activated, because the drawing inside
            // the button is inert and the button around it is what answers.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title ?? capability.name), locked")
            .accessibilityHint("Shows the plans that include it")
        }
    }

    @ViewBuilder
    private var locked: some View {
        switch placement {
        case .corner:
            // On the control's top-trailing corner and hanging off it, the way a notification dot
            // sits on an app icon: most of the mark is over the whitespace above and to the right
            // of the control, and what is left of it is over the corner the control's own glyph
            // does not reach into. The drawing underneath is the drawing the unlocked branch makes,
            // untouched and unwidened, which is the point of the placement.
            inert.overlay(alignment: .topTrailing) {
                PlanLock(capability: capability, diameter: diameter, form: .corner)
                    .offset(x: Self.cornerOverhang, y: -Self.cornerOverhang)
            }
        case .trailing:
            // Over the control's own trailing edge rather than after it: a control that is a whole
            // row has to keep reaching the edge of its card, and the space the badge lands in is
            // the space that row already leaves for a chevron.
            inert.overlay(alignment: .trailing) {
                PlanLock(capability: capability, diameter: diameter)
                    .padding(.trailing, 10)
            }
        }
    }

    /// How far the corner mark hangs off the corner it is pinned to, in both axes.
    ///
    /// Six points, and both ends of that number are decided by something on screen. Below about
    /// four the mark reads as sitting inside the control rather than on it, which is where the
    /// glyph that says what the control is lives. Above about eight it starts to reach whatever the
    /// layout puts next to the control: the two tightest gaps a gated control has to its neighbours
    /// are the 8 points between two chips in the terminal deck and the 6 points between the switch
    /// rows in Settings, and both are read off those layouts rather than guessed at.
    private static var cornerOverhang: CGFloat { 6 }

    /// The control, drawn exactly as the unlocked branch draws it, with the life taken out of it.
    ///
    /// `allowsHitTesting(false)` is what makes the tap land on the button around it rather than on
    /// whatever the label happens to be: several of these are buttons, one is a `ShareLink` and one
    /// is a `Toggle`, and a nested control that keeps its own hit area is a gated control that
    /// still does its own thing.
    private var inert: some View {
        label()
            .opacity(Self.dim)
            .allowsHitTesting(false)
    }
}

extension PlanLocked {
    /// Where the plan badge is drawn when the capability is not included.
    ///
    /// Two shapes rather than one because the two kinds of control are laid out differently, and
    /// the badge has to be legible in both: it may not cover the part of the control that says what
    /// the control is, and it may not push a row in from the edge of its card.
    ///
    /// **There was a third, and it is the one the owner asked to be rid of.** `beside` put the
    /// badge after the control in the layout's own flow, which is honest about what the badge is
    /// and ruinous about what it costs: the control gave up the badge's width, so a locked control
    /// was a different size from the one beside it and every row around it moved. Nothing in the
    /// app used it for anything the other two cannot do, and a placement no site wants is a
    /// placement the next reader has to work out the shape of for nothing.
    enum BadgePlacement {
        /// On the control's top-trailing corner, hung a few points off it: the shape for a control
        /// with a frame of its own (a toolbar glyph, a chip, a circle, a switch). Nothing is given
        /// up for it, here or anywhere around it, so the locked control occupies exactly the space
        /// the unlocked one occupies and lands in exactly the same place.
        case corner
        /// Over the control's trailing edge: the shape for a control that *is* a whole row, whose
        /// surface has to reach the edge of the card and which already leaves room at the end.
        case trailing
    }
}
