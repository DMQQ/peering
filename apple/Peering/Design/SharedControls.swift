import PeeringKit
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
