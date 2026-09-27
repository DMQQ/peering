import MacCastKit
import RemoteCore
import SSHCore
import SwiftUI

/// What the terminal shows while the Mac is starting the shell.
///
/// The panel used to say "Starting login shell…" in the same grey, in the same place, as the
/// output — so the one thing on screen that was *not* the shell looked exactly like the shell, and
/// a terminal that had not printed anything yet was indistinguishable from one that had died. This
/// is drawn as what it is instead: a prompt waiting for a program, with a cursor blinking on it and
/// the sentence filling in underneath.
///
/// A timeline rather than a repeating animation, for the reason given on ``Wordmark``: a
/// `repeatForever` loop is cancelled by whatever re-layout lands on top of it and does not come
/// back, and this one never even gets that far — the state it belongs to is replaced by the first
/// byte of real output, which is a re-layout.
/// Internal rather than private since the SSH terminal became a second caller — see
/// ``SSHTerminalScreen``. "Waiting for a shell to say something" is the same state whether the
/// shell is on the user's Mac or on a server, and a second copy would be the two that drift.
struct TerminalStarting: View {
    /// One tick for both movements. The cursor's blink and the dots filling in are the same kind of
    /// event at the same weight, and running them at two different rates is the thing that makes a
    /// loading screen feel like two loading screens.
    static let tick: TimeInterval = 0.12

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.tick)) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            // On for most of the cycle and off for the rest, which is how a terminal's own cursor
            // behaves: a square wave at even duty reads as a lamp flashing rather than as a cursor.
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
                    // A fixed slot for the dots, so the sentence does not shuffle left and right
                    // three times a second while somebody is reading it.
                    Text(String(repeating: ".", count: dots))
                        .frame(width: 22, alignment: .leading)
                }
            }
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        // Says the one true thing about a moving picture, rather than reading out whichever number
        // of dots the finger happened to land on.
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

    /// The row's height, in the one place both terminals read it from.
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

    /// **The width it is handed, not the width its text wants.** A `UITextField` sizes itself to
    /// its contents and SwiftUI takes that as this view's size, so a long command widened the field
    /// and the whole row with it, pushing the send button off the screen instead of scrolling
    /// inside a field of its own size. The nil case falls back to the field's own answer.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width, height: Self.height)
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        // **Only what this field did not type itself.** ``Coordinator/changed(_:)`` reports every
        // keystroke into ``text``, and while typing fast a render can arrive carrying a value from
        // one or several keystrokes ago. Writing that back wiped what had been typed and put the
        // caret where it was in the older string, so "claude" came out as "laudec". So a mismatch
        // is checked again a turn of the run loop later, against the binding's live value: a stale
        // render has been overtaken by then, and a change from outside (a history chip, a path from
        // the browser, the field emptied by a send) is still there.
        //
        // attributedText rather than `field.text =`, which would strip every attribute the syntax
        // colouring is made of on the next pass.
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

    /// Syntax-coloured version of the command string.
    ///
    /// Three things are coloured, and everything else is white:
    /// - Flags (`-x`, `--long`) are dimmed — they are structure, not the point of the command.
    /// - Quoted strings get the caution amber — the boundaries of a string are what go wrong.
    /// - Shell operators (`|`, `>`, `;`, `&&`, ...) get the accent blue — they are the seams.
    /// Variables (`$VAR`) are slightly dimmed as well.
    static func highlighted(_ text: String) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 17, weight: .regular),
            .foregroundColor: UIColor.white
        ]
        guard !text.isEmpty else { return NSAttributedString(string: text, attributes: base) }
        let out = NSMutableAttributedString(string: text, attributes: base)

        var i = text.startIndex
        while i < text.endIndex {
            // Quoted string: "..." or '...'
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
                    value: UIColor(red: 0.97, green: 0.75, blue: 0.35, alpha: 0.90),
                    range: NSRange(start..<i, in: text))
                continue
            }

            // Shell operators: | ; & > < ( )
            if "|;&><()".contains(text[i]) {
                let start = i
                i = text.index(after: i)
                // Two-character operators: || && >>
                if i < text.endIndex && (text[i] == text[start] || (text[start] == ">" && text[i] == ">")) {
                    i = text.index(after: i)
                }
                out.addAttribute(.foregroundColor, value: UIColor.systemBlue,
                    range: NSRange(start..<i, in: text))
                continue
            }

            // Variable: $VAR or ${VAR}
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

            // Word: command name, argument, or flag
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
            // **Not while the keyboard is still composing.** UIKit forbids replacing the text under
            // a marked range, and a keystroke that arrives inside one — dictation, a candidate, a
            // dead key on a hardware keyboard — is a string UIKit has not committed yet. Doing it
            // there is the second way this field could reorder what was typed; the colour lands on
            // the keystroke that follows instead.
            guard field.markedTextRange == nil else { return }
            // Re-colour after the text changes, preserving the cursor.
            let sel = field.selectedTextRange
            field.attributedText = TerminalCommandField.highlighted(text)
            field.selectedTextRange = sel
        }

        // Feed UIKit focus events back into the SwiftUI binding. Without these, updateUIView
        // sees isFocused=false on the re-render that immediately follows a keystroke (because
        // SwiftUI re-renders on text change before the binding reflects the field's focus), and
        // calls resignFirstResponder() — which is why the keyboard closes on the first letter.
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
    /// The colour a tab wears for this state, or nothing for the states that are not asking for
    /// anything — those are drawn in the strip's own greys.
    ///
    /// Brightness is the palette's rule and hue is its exception, and this is the second place
    /// the exception is earned. A tab is 12 points of monospaced text in a row of near-identical
    /// ones, and three shades of white at arm's length are one shade: "this terminal wants a
    /// password" has to be findable at a glance or it is decoration.
    var tint: Color? {
        switch self {
        case .attention: return ColorPalette.accent
        case .failed: return ColorPalette.danger
        case .starting, .running, .stopped: return nil
        }
    }
}
