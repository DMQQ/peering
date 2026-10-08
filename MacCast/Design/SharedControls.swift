import MacCastKit
import SwiftUI

/// The card-and-row vocabulary the app's settings-shaped screens are built from.
/// `row` takes a label and a control rather than a `Toggle` or `Picker`: split apart they are the same shape.
enum Controls {
    /// Not ``SectionLabel``: Settings headings label the rows under them, while these cards are named after objects.
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
            // The title goes on the `Toggle` and is hidden, so the switch keeps a name to be read out.
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .tint(ColorPalette.accent)
        }
    }

    /// The tint is what the value is printed in: left alone it is the accent, which here means "this is on".
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

    static var divider: some View {
        Divider().overlay(.white.opacity(0.07))
    }
}

// MARK: - Locked controls

/// The plan a control needs, drawn on that control: its name, in the same word the selling card and the sheet use.
/// `corner` exists because `control` took the layout's width everywhere, so a plan changing under a thumb reshuffled a row of keys.
struct PlanLock: View {
    let capability: PlanCapability
    /// Roughly the size of the control it belongs to; `corner` reads it only at the top of the range.
    var diameter: CGFloat = 30
    var form: Form = .control

    enum Form {
        case control
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

    /// Between eight and a half and ten points: small enough to read as a mark, still a word.
    private var cornerTypeSize: CGFloat { max(8.5, min(10, diameter * 0.25)) }

    /// `fixedSize` keeps it legible on the smallest control: an overlay is proposed the control's size, and the badge would otherwise split into two lines.
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
            // Hidden because the button around it carries the whole sentence ("Macros, locked").
            .accessibilityHidden(true)
    }
}

/// Never a padlock or a badge in the control's place: "Add a server" with the plus taken away does not say what the button does. The badge hangs off the corner so a locked control costs the layout exactly what the unlocked one does.
/// One type so every gate opens the paywall at the feature door and says what was locked.
struct PlanLocked<Label: View>: View {
    let capability: PlanCapability
    /// Where it differs from the capability's name: a toolbar glyph has no row, and "New shell, locked" is what was pressed.
    var title: String?
    /// `corner` is the default: it takes nothing from the layout.
    var placement: BadgePlacement = .corner
    var diameter: CGFloat = 30
    /// `nil` asks the map. The three passing a value are a first thing free on every plan (the terminal's `+` and the two pairing rows); asking the map would take the free one away.
    var isIncluded: Bool?
    @ViewBuilder var label: () -> Label

    @Environment(SessionModel.self) private var model

    /// Not `.disabled()`: the tap has to reach the button around it.
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
            // One element: the inner drawing is inert and the button answers, so VoiceOver would find a control that reads as live and does nothing.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title ?? capability.name), locked")
            .accessibilityHint("Shows the plans that include it")
        }
    }

    @ViewBuilder
    private var locked: some View {
        switch placement {
        case .corner:
            // On the top-trailing corner, hanging off it, over whitespace and the corner the glyph does not reach.
            inert.overlay(alignment: .topTrailing) {
                PlanLock(capability: capability, diameter: diameter, form: .corner)
                    .offset(x: Self.cornerOverhang, y: -Self.cornerOverhang)
            }
        case .trailing:
            // Over the trailing edge, not after it: a whole-row control must keep reaching the card's edge, and the badge lands where a chevron goes.
            inert.overlay(alignment: .trailing) {
                PlanLock(capability: capability, diameter: diameter)
                    .padding(.trailing, 10)
            }
        }
    }

    /// Below about four the mark sits inside the control; above about eight it reaches the neighbour (gaps are 8 points between terminal chips and 6 between Settings switch rows).
    private static var cornerOverhang: CGFloat { 6 }

    /// `allowsHitTesting(false)` sends the tap to the button around it: nested controls (a `ShareLink`, a `Toggle`) would otherwise do their own thing.
    private var inert: some View {
        label()
            .opacity(Self.dim)
            .allowsHitTesting(false)
    }
}

extension PlanLocked {
    enum BadgePlacement {
        case corner
        case trailing
    }
}
