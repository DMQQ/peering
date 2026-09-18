import SwiftUI

/// The six dots a passcode fills in, and — when the wrong one was typed — the colour they turn.
///
/// Shared by the two places a passcode is typed: the sheet that sets one and the lock that asks
/// for it. They are the same act with different sentences above them, and two pads would be two
/// chances for the second one to be a little different from the first.
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

/// The keys.
///
/// A pad rather than a text field, and this is the one place in the app where that is true. A field
/// brings a keyboard that covers half the sheet, a caret, a selection, and the possibility of
/// pasting in something that is not six digits — none of which a passcode needs, and all of which
/// are things to get wrong. Twelve fixed keys cannot be got wrong.
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
                // Empty rather than another key, so the zero sits under the eight where a keypad
                // puts it instead of in the middle of a row of three.
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
