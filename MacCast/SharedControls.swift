import MacCastKit
import SwiftUI

/// The card-and-row vocabulary the app's settings-shaped screens are built from.
///
/// `row` takes a *label and a control* rather than a `Toggle` or a `Picker`: split apart, a picker
/// and a switch are the same shape, and every row starts with a glyph and a name.
enum Controls {
    /// The heading on a card of rows: a glyph and a name, in the sentence case the Connect and
    /// Sessions tabs use.
    ///
    /// Not ``SectionLabel``, the uppercase one: Settings is a list of labelled questions and its
    /// headings are labels *of* the rows under them, while these cards are named after objects.
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
    /// The tint is what the value is printed in: left alone it is the accent, which here means
    /// "this is on" and nothing else, since a picked value is a setting's answer rather than a
    /// state.
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

    /// The small tile a row's glyph sits in: a third of the size of ``IconTile``, the same object at
    /// a smaller scale.
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

    /// Between two rows, and never after the last one: a rule under the bottom row is a line with
    /// nothing on the other side of it.
    static var divider: some View {
        Divider().overlay(.white.opacity(0.07))
    }
}

// MARK: - Locked controls

/// The plan a control needs, drawn on that control rather than beside it or in its place: the name
/// of the plan, and the same word the card that sells it and the sheet this opens use.
///
/// ``Form/control`` is the badge as a peer of the control, drawn to roughly its height so a column
/// of them still lines up. ``Form/corner`` is a mark pinned to a control's top-trailing corner at a
/// fraction of that height, and exists because the first took the layout's width everywhere it
/// appeared, so a plan changing under a thumb reshuffled a row of keys.
///
/// Hidden from VoiceOver in both forms: the control under the badge carries the whole sentence.
struct PlanLock: View {
    /// The plan that unlocks it. The badge is its name, the same word the card that sells it and
    /// the sheet this opens use.
    let capability: PlanCapability
    /// Roughly the size of the control it belongs to: a row's switch is about 30 across, a toolbar
    /// glyph less, the deck's chips more.
    ///
    /// The ``Form/control`` badge is drawn to this height. The ``Form/corner`` mark reads it only at
    /// the top of that range, and is otherwise the same size at every gate in the app.
    var diameter: CGFloat = 30
    /// Which of the two drawings this is. See ``Form``.
    var form: Form = .control

    /// The two shapes the same word is drawn in.
    ///
    /// Same tint, capsule and accessibility in both: the difference is size, not meaning. One takes
    /// room in the layout and the other takes none.
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
    /// Between eight and a half and ten points whatever it sits on: small enough to read as a mark
    /// rather than a second control, and still a word. The deck's chips are the one site that takes
    /// the larger size.
    private var cornerTypeSize: CGFloat { max(8.5, min(10, diameter * 0.25)) }

    /// The plan's name in its capsule, at whatever size the form asks for.
    ///
    /// `fixedSize` is what keeps this legible on the smallest control: an overlay is proposed the
    /// size of the control underneath it, and a toolbar glyph is narrower than the word PLUS, so
    /// without it the badge comes apart into two lines.
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
            // Hidden because the button around it carries the whole sentence: read on its own this
            // is a plan name with no verb, and what a VoiceOver user needs is "Macros, locked".
            .accessibilityHidden(true)
    }
}

/// A gated control: the control itself, drawn exactly as the unlocked branch draws it, dimmed and
/// inert inside a button that opens the plans, with the plan's name on its corner when the plan
/// does not include it.
///
/// Never a padlock and never a badge in the control's place: a user looking at "Add a server" with
/// the plus taken away cannot tell what the button does. The badge hangs off the corner because a
/// locked control has to cost the layout exactly what the unlocked one costs, so the layout is the
/// unlocked layout. See ``BadgePlacement`` for which control gets which.
///
/// One type rather than the same three lines at each gate, so every one opens the paywall at the
/// *feature* door and says out loud what was locked. The label is the capability's own name, since
/// the row and the sheet are the same value.
struct PlanLocked<Label: View>: View {
    let capability: PlanCapability
    /// What the control is called, where it differs from the capability's own name: a toolbar glyph
    /// has no row around it, and "New shell, locked" is what was pressed where the app sells
    /// "Several shells at once, locked".
    var title: String?
    /// Where the badge goes, which follows from what the control is. See ``BadgePlacement``.
    ///
    /// ``BadgePlacement/corner`` is the default: it takes nothing from the layout, so a control with
    /// a frame of its own is the same size locked as it is unlocked.
    var placement: BadgePlacement = .corner
    /// Roughly the size of the control. The badge takes its own scale from it, which is a
    /// proportional one beside a control and a nearly fixed one on its corner: see the parameter on
    /// ``PlanLock``.
    var diameter: CGFloat = 30
    /// Whether the control is live, where that is not the same question as whether the plan
    /// includes the capability.
    ///
    /// `nil` means ask the map, which is what every gate in the app does. The three sites that pass
    /// a value are a *first* thing being free on every plan: the terminal's `+`, which is only paid
    /// once there is a shell to be concurrent with, and the two pairing rows. Asking the map alone
    /// at those sites would take the free one away.
    var isIncluded: Bool?
    @ViewBuilder var label: () -> Label

    @Environment(SessionModel.self) private var model

    /// How far a gated control is taken down.
    ///
    /// Not `.disabled()`: that would make the *inner* control the thing that answers a press, and
    /// the tap has to reach the button around it. Far enough that nobody mistakes it for live, and
    /// not so far that the words stop saying what the control is.
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
            // One element, not two: the drawing inside is inert and the button around it answers, so
            // without this VoiceOver would find a control that reads as live and does nothing.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title ?? capability.name), locked")
            .accessibilityHint("Shows the plans that include it")
        }
    }

    @ViewBuilder
    private var locked: some View {
        switch placement {
        case .corner:
            // On the top-trailing corner and hanging off it, so most of the mark is over whitespace
            // and the rest over the corner the control's own glyph does not reach into. The drawing
            // underneath is the unlocked branch's, untouched and unwidened.
            inert.overlay(alignment: .topTrailing) {
                PlanLock(capability: capability, diameter: diameter, form: .corner)
                    .offset(x: Self.cornerOverhang, y: -Self.cornerOverhang)
            }
        case .trailing:
            // Over the control's own trailing edge rather than after it: a whole-row control has to
            // keep reaching the edge of its card, and the badge lands in the space the row already
            // leaves for a chevron.
            inert.overlay(alignment: .trailing) {
                PlanLock(capability: capability, diameter: diameter)
                    .padding(.trailing, 10)
            }
        }
    }

    /// How far the corner mark hangs off the corner it is pinned to, in both axes.
    ///
    /// Below about four the mark reads as sitting inside the control rather than on it, which is
    /// where the glyph that says what the control is lives. Above about eight it reaches whatever
    /// the layout puts next to the control: the tightest gaps are the 8 points between two chips in
    /// the terminal deck and the 6 points between the switch rows in Settings.
    private static var cornerOverhang: CGFloat { 6 }

    /// The control, drawn exactly as the unlocked branch draws it, with the life taken out of it.
    ///
    /// `allowsHitTesting(false)` sends the tap to the button around it: several of these labels are
    /// buttons, one is a `ShareLink` and one a `Toggle`, and a nested control that keeps its own hit
    /// area still does its own thing.
    private var inert: some View {
        label()
            .opacity(Self.dim)
            .allowsHitTesting(false)
    }
}

extension PlanLocked {
    /// Where the plan badge is drawn when the capability is not included.
    ///
    /// Two shapes, because the badge may not cover the part of the control that says what the
    /// control is, and may not push a row in from the edge of its card.
    enum BadgePlacement {
        /// On the control's top-trailing corner, hung a few points off it: the shape for a control
        /// with a frame of its own. Nothing is given up for it, so the locked control occupies
        /// exactly the space the unlocked one occupies.
        case corner
        /// Over the control's trailing edge: the shape for a control that *is* a whole row, whose
        /// surface has to reach the edge of the card and which already leaves room at the end.
        case trailing
    }
}
