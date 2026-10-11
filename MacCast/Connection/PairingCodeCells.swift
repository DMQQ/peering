import SwiftUI

/// Six digits as six boxes, the way a code is read off a Mac and typed. Any filled box can be tapped and retyped, so one wrong digit does not mean starting again.
/// A single text field cannot hold a cursor in the middle of boxes, so the field is invisible and only catches keystrokes: it always holds one placeholder character, a character added to it is a digit typed, and the placeholder vanishing is a delete. Both are applied to the selected box and the field is reset.
struct PairingCodeCells: View {
    @Binding var text: String
    var isWrong = false
    var focus: FocusState<Bool>.Binding
    var onEdit: () -> Void = {}

    private static let count = 6
    private static let placeholder = "•"

    @State private var field = placeholder
    @State private var selected = 0

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                ForEach(0..<Self.count, id: \.self) { index in
                    cell(at: index)
                        .contentShape(Rectangle())
                        .onTapGesture { select(index) }
                }
            }

            TextField("", text: $field)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused(focus)
                .foregroundStyle(.clear)
                .tint(.clear)
                .opacity(0.02)
                .frame(width: 1, height: 1)
                .onChange(of: field) { _, newValue in absorb(newValue) }
        }
        .onChange(of: text) { _, newValue in selected = min(selected, min(newValue.count, Self.count - 1)) }
        .onAppear { selected = min(text.count, Self.count - 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Pairing code"))
        .accessibilityValue(Text(text))
        .accessibilityAddTraits(.isButton)
    }

    private func select(_ index: Int) {
        selected = min(index, min(text.count, Self.count - 1))
        onEdit()
        focus.wrappedValue = true
    }

    /// A whole code at once (the one-time-code suggestion, a paste) replaces everything; one character is a keystroke for the selected box.
    private func absorb(_ value: String) {
        guard value != Self.placeholder else { return }
        defer { field = Self.placeholder }
        let digits = value.replacingOccurrences(of: Self.placeholder, with: "").filter(\.isNumber)
        onEdit()

        if value.isEmpty {
            guard !text.isEmpty else { return }
            var chars = Array(text)
            let index = min(selected, chars.count - 1)
            chars.remove(at: index)
            text = String(chars)
            selected = max(0, index - (index == chars.count ? 1 : 0))
            return
        }
        if digits.count > 1 {
            text = String(digits.prefix(Self.count))
            selected = min(text.count, Self.count - 1)
            return
        }
        guard let digit = digits.first else { return }
        var chars = Array(text)
        if selected < chars.count { chars[selected] = digit } else { chars.append(digit) }
        text = String(chars.prefix(Self.count))
        selected = min(selected + 1, Self.count - 1, text.count)
    }

    private func cell(at index: Int) -> some View {
        let digits = Array(text)
        let isCurrent = focus.wrappedValue && !isWrong && index == selected
        return Text(index < digits.count ? String(digits[index]) : "")
            .font(.system(size: 28, weight: .semibold, design: .monospaced))
            .foregroundStyle(isWrong ? ColorPalette.danger : ColorPalette.ink)
            .frame(maxWidth: .infinity, minHeight: 60)
            .rowSurface()
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isWrong ? ColorPalette.danger : ColorPalette.accent, lineWidth: 1.5)
                    .opacity(isWrong || isCurrent ? 1 : 0)
            }
            .animation(Motion.tap, value: isCurrent)
            .animation(.easeOut(duration: 0.12), value: isWrong)
    }
}

/// Moves a view side to side as `animatableData` climbs by one per shake, so a wrong answer is felt before it is read.
struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 9 * sin(animatableData * .pi * 4), y: 0))
    }
}
