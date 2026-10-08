import SwiftUI

/// The passcode dots and keys, shared by the set and unlock sheets.
struct PasscodeDots: View {
    let filled: Int
    let total: Int
    let isRejected: Bool

    var body: some View {
        HStack(spacing: 14) {
            ForEach(0..<total, id: \.self) { index in
                Circle()
                    .strokeBorder(
                        isRejected ? ColorPalette.danger : ColorPalette.ink.opacity(0.35),
                        lineWidth: 1.5
                    )
                    .background {
                        Circle().fill(
                            index < filled
                                ? (isRejected ? ColorPalette.danger : ColorPalette.ink)
                                : .clear
                        )
                    }
                    .frame(width: 14, height: 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement()
        .accessibilityLabel("\(filled) of \(total) digits entered")
    }
}

/// A fixed pad rather than a text field: no keyboard covering the sheet and no pasting non-digits.
struct PasscodePad: View {
    let onDigit: (Int) -> Void
    let onDelete: () -> Void

    private let keyHeight: CGFloat = 46

    var body: some View {
        VStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 10) {
                    ForEach(1...3, id: \.self) { column in
                        let digit = row * 3 + column
                        padKey(action: { onDigit(digit) }) {
                            Text(String(digit))
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Color.clear.frame(maxWidth: .infinity, minHeight: keyHeight)

                padKey(action: { onDigit(0) }) {
                    Text("0")
                }

                padKey(action: onDelete) {
                    Image(systemName: "delete.left")
                        .font(.system(size: 18, weight: .medium))
                }
                .accessibilityLabel("Delete the last digit")
            }
        }
    }

    private func padKey<Content: View>(
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button {
            action()
        } label: {
            content()
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(ColorPalette.ink)
                .frame(maxWidth: .infinity, minHeight: keyHeight)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(ColorPalette.surface)
                }
        }
        .buttonStyle(.plain)
    }
}
