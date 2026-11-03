import RemoteCore
import SwiftUI
import UIKit

/// Held by a field because autocorrection, prediction and dictation belong to the text system, which needs a document to offer them to. What the Mac is told is what the field just did, including the system's own replacements. Also the only place on this side a caret can be anywhere but the end.
final class KeyboardTypingView: UITextView, UITextViewDelegate {
    static func font(large: Bool) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: large ? 17 : 13, weight: .regular)
    }

    /// Larger while the shortcut keys are folded away, since the room they took goes to the text.
    var isLarge = false {
        didSet {
            guard isLarge != oldValue else { return }
            font = Self.font(large: isLarge)
            hint.font = font
        }
    }

    /// One line, growing to a cap past which the text view scrolls and keeps the caret in view.
    var oneLineHeight: CGFloat { ((font ?? Self.font(large: false)).lineHeight + 8).rounded() }
    var maximumHeight: CGFloat { ((font ?? Self.font(large: false)).lineHeight * (isLarge ? 5 : 4) + 10).rounded() }

    var onType: ((String) -> Void)?
    var onDelete: ((Int) -> Void)?
    var onKey: ((UIKeyboardHIDUsage, Bool, UIKeyModifierFlags) -> Void)?
    var onReturn: (() -> Void)?
    var onDraftChange: ((String) -> Void)?

    private let hint = UILabel()

    init() {
        super.init(frame: .zero, textContainer: nil)
        delegate = self
        isScrollEnabled = true
        // No insets of its own. Reaching `textContainer` puts this on TextKit 1, the compatibility path.
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0

        autocorrectionType = .yes
        // Not spelled out: terminal output is not English prose, and a red underline under a path reads as a warning about the path.
        spellCheckingType = .no
        // Capitalisation off: this types into the Mac's own applications, and a shell prompt capitalising each command is worse.
        autocapitalizationType = .none
        keyboardType = .default
        returnKeyType = .send

        font = Self.font(large: false)
        textColor = .white
        tintColor = .white
        backgroundColor = .clear

        hint.text = String(localized: "Typing…")
        hint.font = Self.font(large: false)
        hint.textColor = .placeholderText
        hint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hint)
        NSLayoutConstraint.activate([
            hint.leadingAnchor.constraint(equalTo: leadingAnchor),
            hint.topAnchor.constraint(equalTo: topAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not built from a nib") }

    /// Sends the edit, then lets the field do it: the field must keep the text because it is the document autocorrection reads, and a correction arrives as a replacement.
    func textView(
        _ textView: UITextView,
        shouldChangeTextIn range: NSRange,
        replacementText text: String
    ) -> Bool {
        // Return is a key the Mac gets, not a newline this field keeps. The check is on the whole replacement, not equality with "\n": the system commits a pending correction and Return together, so "word\n" arrived as one edit and no Return was sent.
        if text.contains("\n") {
            let typed = text.replacingOccurrences(of: "\n", with: "")
            if !typed.isEmpty { onType?(typed) }
            reset()
            onReturn?()
            return false
        }
        // Counted in characters: a backspace removes one, and the range arrives in UTF-16 units where an emoji is two.
        let replaced = (textView.text as NSString).substring(with: range).count
        if replaced > 0 { onDelete?(replaced) }
        if !text.isEmpty { onType?(text) }
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        hint.isHidden = !textView.text.isEmpty
        onDraftChange?(textView.text)
    }

    func restore(_ draft: String) {
        text = draft
        hint.isHidden = !draft.isEmpty
    }

    /// Left alone mid-composition, which the system would otherwise lose.
    func apply(_ draft: String, selection: NSRange) {
        guard markedTextRange == nil else { return }
        if text != draft { restore(draft) }
        let length = (text as NSString).length
        let location = min(max(selection.location, 0), length)
        let clamped = NSRange(location: location, length: min(max(selection.length, 0), length - location))
        if selectedRange != clamped { selectedRange = clamped }
    }

    var appliedFieldSerial = 0

    func reset() {
        text = ""
        hint.isHidden = false
        onDraftChange?("")
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            handled = true
            onKey?(key.keyCode, true, key.modifierFlags)
        }
        // Swallowed, as the view above does: a press left to `super` would be turned into text by the text system and arrive twice.
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            handled = true
            onKey?(key.keyCode, false, key.modifierFlags)
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)
    }
}

