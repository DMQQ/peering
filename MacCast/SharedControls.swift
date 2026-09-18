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
