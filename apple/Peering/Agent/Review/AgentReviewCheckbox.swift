import SwiftUI

/// The square at the left of a file row. It selects the file; whether it was reviewed is told elsewhere in the row.
struct AgentReviewCheckbox: View {
    let isSelected: Bool
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? ColorPalette.ink : .clear)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isSelected ? .clear : .white.opacity(0.4), lineWidth: 1.5)
                }
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(ColorPalette.onInk)
                    }
                }
                .frame(width: 22, height: 22)
                .frame(width: 34, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Motion.tap, value: isSelected)
        .accessibilityLabel(Text("Select file"))
        .accessibilityValue(Text(isSelected ? "Selected" : "Not selected"))
        .accessibilityIdentifier(identifier)
    }
}
