import MacCastKit
import RemoteCore
import SSHCore
import SwiftUI

/// What the terminal shows while the shell is starting, drawn as a prompt with a blinking cursor so it cannot be mistaken for a dead shell.
/// A timeline, not `repeatForever`, which a re-layout cancels. Shared by the SSH terminal.
struct TerminalStarting: View {
    static let tick: TimeInterval = 0.12

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.tick)) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let caretIsOn = elapsed.truncatingRemainder(dividingBy: 1.0) < 0.62
            let dots = Int(elapsed.truncatingRemainder(dividingBy: 1.2) / 0.4) + 1

            VStack(spacing: 13) {
                HStack(spacing: 7) {
                    Text("❯")
                        .foregroundStyle(ColorPalette.accent)
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(ColorPalette.ink)
                        .frame(width: 9, height: 16)
                        .opacity(caretIsOn ? 1 : 0)
                }

                HStack(spacing: 0) {
                    Text("Starting login shell")
                    Text(String(repeating: ".", count: dots))
                        .frame(width: 22, alignment: .leading)
                }
            }
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Starting login shell")
    }
}

/// A terminal command field whose Return key is handled without resigning first responder. SwiftUI
/// TextField's submit action dismisses the keyboard before its callback, which creates a visible
/// close/reopen cycle even when focus is immediately restored.
struct TerminalCommandField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String
    let isEnabled: Bool
    let onSubmit: () -> Void

    static let height: CGFloat = 30

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.returnKeyType = .send
        field.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
        field.textColor = .white
        field.tintColor = .white
        field.clearButtonMode = .never
        return field
    }

    /// The width handed in, not the text width: a `UITextField` sizes to its contents, so a long command pushed the send button off screen.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width, height: Self.height)
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        // Only what this field did not type itself, re-checked a run-loop turn later against the live binding: a stale render carrying an older value wiped typing ("claude" came out "laudec").
        // attributedText, not `field.text =`, which strips the syntax colouring.
        if text != (field.text ?? "") {
            let binding = $text
            DispatchQueue.main.async {
                let live = binding.wrappedValue
                guard live != (field.text ?? ""), field.markedTextRange == nil else { return }
                field.attributedText = Self.highlighted(live)
                let end = field.endOfDocument
                field.selectedTextRange = field.textRange(from: end, to: end)
            }
        }
        field.placeholder = placeholder
        field.isEnabled = isEnabled
        if isFocused, !field.isFirstResponder {
            field.becomeFirstResponder()
        } else if !isFocused, field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    static func highlighted(_ text: String) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 17, weight: .regular),
            .foregroundColor: UIColor.white
        ]
        guard !text.isEmpty else { return NSAttributedString(string: text, attributes: base) }
        let out = NSMutableAttributedString(string: text, attributes: base)

        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "\"" || text[i] == "'" {
                let q = text[i]; let start = i
                i = text.index(after: i)
                while i < text.endIndex && text[i] != q {
                    if text[i] == "\\" {
                        i = text.index(after: i)
                        if i < text.endIndex { i = text.index(after: i) }
                    } else {
                        i = text.index(after: i)
                    }
                }
                if i < text.endIndex { i = text.index(after: i) }
                out.addAttribute(.foregroundColor,
                    value: UIColor(ColorPalette.caution),
                    range: NSRange(start..<i, in: text))
                continue
            }

            if "|;&><()".contains(text[i]) {
                let start = i
                i = text.index(after: i)
                if i < text.endIndex && (text[i] == text[start] || (text[start] == ">" && text[i] == ">")) {
                    i = text.index(after: i)
                }
                out.addAttribute(.foregroundColor, value: UIColor.systemBlue,
                    range: NSRange(start..<i, in: text))
                continue
            }

            if text[i] == "$" {
                let start = i
                i = text.index(after: i)
                if i < text.endIndex && text[i] == "{" {
                    i = text.index(after: i)
                    while i < text.endIndex && text[i] != "}" { i = text.index(after: i) }
                    if i < text.endIndex { i = text.index(after: i) }
                } else {
                    while i < text.endIndex && (text[i].isLetter || text[i].isNumber || text[i] == "_") {
                        i = text.index(after: i)
                    }
                }
                out.addAttribute(.foregroundColor, value: UIColor.white.withAlphaComponent(0.65),
                    range: NSRange(start..<i, in: text))
                continue
            }

            if !text[i].isWhitespace {
                let start = i
                while i < text.endIndex && !text[i].isWhitespace && !"\"'|;&><$()".contains(text[i]) {
                    i = text.index(after: i)
                }
                if String(text[start..<i]).hasPrefix("-") {
                    out.addAttribute(.foregroundColor, value: UIColor.white.withAlphaComponent(0.50),
                        range: NSRange(start..<i, in: text))
                }
                continue
            }

            i = text.index(after: i)
        }

        return out
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: TerminalCommandField

        init(_ parent: TerminalCommandField) { self.parent = parent }

        @objc func changed(_ field: UITextField) {
            let text = field.text ?? ""
            parent.text = text
            // Not while composing: UIKit forbids replacing text under a marked range (dictation, candidates, dead keys).
            guard field.markedTextRange == nil else { return }
            let sel = field.selectedTextRange
            field.attributedText = TerminalCommandField.highlighted(text)
            field.selectedTextRange = sel
        }

        // Feed focus events back to the binding, or updateUIView sees isFocused=false after a keystroke and resigns first responder, closing the keyboard on the first letter.
        func textFieldDidBeginEditing(_ textField: UITextField) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            if parent.isFocused { parent.isFocused = false }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }
}

extension TerminalState {
    /// A tab is 12 points of monospaced text among near-identical ones, so states that ask for something need hue to be findable; the rest stay grey.
    var tint: Color? {
        switch self {
        case .attention: return ColorPalette.accent
        case .failed: return ColorPalette.danger
        case .starting, .running, .stopped: return nil
        }
    }
}
