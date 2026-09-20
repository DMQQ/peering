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

/// The plan a control needs, worn beside that control rather than in its place.
///
/// **The badge, not the gate.** A capsule saying RELAY, PLUS or PRO is the same word the cards and
/// the sheet use, so the badge, the tap and the purchase all name one thing: what is drawn here is
/// the name of the plan, and what unlocks the control beside it.
///
/// It used to be the gate as well, worn where the control would have been, which is how a row
/// reading "Add a server" came to end in a badge with the plus taken away. ``PlanLocked`` records
/// why that was wrong twice over; this type is what is left of it, and the only thing it decides
/// now is how a plan's name is drawn at the size of the control it sits next to.
///
/// Drawn to roughly the height of that control, so it lands at the same optical weight and a row of
/// them still lines up, and hidden from VoiceOver because the control it sits beside carries the
/// whole sentence. Read on its own this is a plan name with no verb.
struct PlanLock: View {
    /// The plan that unlocks it. The badge is its name, because the same word has to appear here,
    /// on the card that sells it and in the sheet this opens.
    let capability: PlanCapability
    /// Roughly the size of the control beside it: a row's switch is about 30 across, a toolbar
    /// glyph less, the deck's chips more. The badge is drawn to this height and no wider than its
    /// own text needs.
    var diameter: CGFloat = 30

    var body: some View {
        Text(capability.minimumPlan.badge)
            .font(.system(size: max(9, diameter * 0.32), weight: .bold))
            .tracking(0.5)
            .foregroundStyle(ColorPalette.accent)
            .padding(.horizontal, diameter * 0.3)
            .padding(.vertical, diameter * 0.17)
            .background(ColorPalette.accent.opacity(0.18), in: Capsule())
            // Hidden because the button around it carries the whole sentence. Read on its own this
            // is a plan name with no verb, and what a VoiceOver user needs is "Macros, locked".
            .accessibilityHidden(true)
    }
}

/// A gated control: the control itself, and the plan badge beside it when the plan does not
/// include it.
///
/// **The control is drawn as itself, in its own shape and with its own glyph, dimmed, with a small
/// plan-name badge beside it. Tapping it opens the paywall. Never a padlock, never a badge in the
/// control's place.** That is the owner's rule for every gate in the app, and it is the third
/// attempt: the first two are worth recording, because both were argued for at the time.
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
/// is the badge, which is why the badge goes *beside* the control and never in its place.
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
    var placement: BadgePlacement = .beside
    /// Roughly the size of the control, so the badge beside it is drawn at the same optical weight
    /// rather than at a fixed one.
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
        case .beside:
            HStack(spacing: 8) {
                inert
                PlanLock(capability: capability, diameter: diameter)
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
    /// the badge has to be legible in both: it may not cover the control it belongs to, and it may
    /// not push a row in from the edge of its card.
    enum BadgePlacement {
        /// After the control, in the layout's own flow: the shape for a control with a frame of its
        /// own (a toolbar glyph, a chip, a circle, a switch). The control gives up the badge's
        /// width, so it is the shape for anything whose width is not the point.
        case beside
        /// Over the control's trailing edge: the shape for a control that *is* a whole row, whose
        /// surface has to reach the edge of the card and which already leaves room at the end.
        case trailing
    }
}
