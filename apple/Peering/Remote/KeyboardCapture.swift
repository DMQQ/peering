import RemoteCore
import SwiftUI
import UIKit

/// Conversions between what iOS reports and what macOS injects. iOS reports a USB HID usage (`A` is 4); macOS injects a virtual keycode from `Events.h` (`A` is 0). Sending one where the other is expected types a plausible wrong character.
enum KeycodeMap {
    static func macOSKeycode(for usage: UIKeyboardHIDUsage) -> UInt16? {
        switch usage {
        case .keyboardA: return 0
        case .keyboardS: return 1
        case .keyboardD: return 2
        case .keyboardF: return 3
        case .keyboardH: return 4
        case .keyboardG: return 5
        case .keyboardZ: return 6
        case .keyboardX: return 7
        case .keyboardC: return 8
        case .keyboardV: return 9
        case .keyboardB: return 11
        case .keyboardQ: return 12
        case .keyboardW: return 13
        case .keyboardE: return 14
        case .keyboardR: return 15
        case .keyboardY: return 16
        case .keyboardT: return 17
        case .keyboardO: return 31
        case .keyboardU: return 32
        case .keyboardI: return 34
        case .keyboardP: return 35
        case .keyboardL: return 37
        case .keyboardJ: return 38
        case .keyboardK: return 40
        case .keyboardN: return 45
        case .keyboardM: return 46

        case .keyboard1: return 18
        case .keyboard2: return 19
        case .keyboard3: return 20
        case .keyboard4: return 21
        case .keyboard5: return 23
        case .keyboard6: return 22
        case .keyboard7: return 26
        case .keyboard8: return 28
        case .keyboard9: return 25
        case .keyboard0: return 29

        case .keyboardHyphen: return 27
        case .keyboardEqualSign: return 24
        case .keyboardOpenBracket: return 33
        case .keyboardCloseBracket: return 30
        case .keyboardBackslash: return 42
        case .keyboardSemicolon: return 41
        case .keyboardQuote: return 39
        case .keyboardGraveAccentAndTilde: return 50
        case .keyboardComma: return 43
        case .keyboardPeriod: return 47
        case .keyboardSlash: return 44

        case .keyboardReturnOrEnter: return 36
        case .keyboardEscape: return 53
        case .keyboardDeleteOrBackspace: return 51
        case .keyboardDeleteForward: return 117
        case .keyboardTab: return 48
        case .keyboardSpacebar: return 49
        case .keyboardCapsLock: return 57
        case .keyboardHome: return 115
        case .keyboardEnd: return 119
        case .keyboardPageUp: return 116
        case .keyboardPageDown: return 121
        case .keyboardLeftArrow: return 123
        case .keyboardRightArrow: return 124
        case .keyboardDownArrow: return 125
        case .keyboardUpArrow: return 126

        // Modifiers. Left and right collapse to one keycode each because the protocol's
        // `Modifiers` bitmask has no way to distinguish them — see `InputEncoding`.
        case .keyboardLeftShift, .keyboardRightShift: return 56
        case .keyboardLeftControl, .keyboardRightControl: return 59
        case .keyboardLeftAlt, .keyboardRightAlt: return 58
        case .keyboardLeftGUI, .keyboardRightGUI: return 55

        case .keyboardF1: return 122
        case .keyboardF2: return 120
        case .keyboardF3: return 99
        case .keyboardF4: return 118
        case .keyboardF5: return 96
        case .keyboardF6: return 97
        case .keyboardF7: return 98
        case .keyboardF8: return 100
        case .keyboardF9: return 101
        case .keyboardF10: return 109
        case .keyboardF11: return 103
        case .keyboardF12: return 111

        default: return nil
        }
    }

    /// US layout only: iOS does not say which layout the Mac uses, so an AZERTY phone in keycode mode produces QWERTY positions. That is why Unicode mode is the default.
    static func macOSKeycode(forCharacter character: Character) -> UInt16? {
        // Case is carried by shift, not the keycode; the caller pairs this with ``characterNeedsShift(_:)``.
        let lowered = Character(character.lowercased())

        switch lowered {
        case "a": return 0
        case "s": return 1
        case "d": return 2
        case "f": return 3
        case "h": return 4
        case "g": return 5
        case "z": return 6
        case "x": return 7
        case "c": return 8
        case "v": return 9
        case "b": return 11
        case "q": return 12
        case "w": return 13
        case "e": return 14
        case "r": return 15
        case "y": return 16
        case "t": return 17
        case "o": return 31
        case "u": return 32
        case "i": return 34
        case "p": return 35
        case "l": return 37
        case "j": return 38
        case "k": return 40
        case "n": return 45
        case "m": return 46

        case "1": return 18
        case "2": return 19
        case "3": return 20
        case "4": return 21
        case "5": return 23
        case "6": return 22
        case "7": return 26
        case "8": return 28
        case "9": return 25
        case "0": return 29

        case "-": return 27
        case "=": return 24
        case "[": return 33
        case "]": return 30
        case "\\": return 42
        case ";": return 41
        case "'": return 39
        case "`": return 50
        case ",": return 43
        case ".": return 47
        case "/": return 44
        case " ": return 49
        case "\n", "\r": return 36
        case "\t": return 48

        case "!": return 18
        case "@": return 19
        case "#": return 20
        case "$": return 21
        case "%": return 23
        case "^": return 22
        case "&": return 26
        case "*": return 28
        case "(": return 25
        case ")": return 29
        case "_": return 27
        case "+": return 24
        case "{": return 33
        case "}": return 30
        case "|": return 42
        case ":": return 41
        case "\"": return 39
        case "~": return 50
        case "<": return 43
        case ">": return 47
        case "?": return 44

        default: return nil
        }
    }

    /// `A`, `!` and `$` are the same key with shift held and the keycode cannot recover it, so it is computed from the character where characters become commands.
    static func characterNeedsShift(_ character: Character) -> Bool {
        if character.isUppercase { return true }
        return "!@#$%^&*()_+{}|:\"~<>?".contains(character)
    }

    static func modifiers(from flags: UIKeyModifierFlags) -> Modifiers {
        var modifiers: Modifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.alternate) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }
}

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

struct KeyboardTypingCapture: UIViewRepresentable {
    let model: SessionModel
    var isLarge = false
    @Binding var isFocused: Bool

    func makeUIView(context: Context) -> KeyboardTypingView {
        let view = KeyboardTypingView()
        view.onType = { [weak model] text in model?.handleTypedText(text) }
        view.onDelete = { [weak model] count in
            // One at a time, which is what the Mac hears either way: a correction that replaced a word drops exactly its characters.
            for _ in 0..<count { model?.handleBackspace() }
        }
        view.onReturn = { [weak model] in model?.pressReturn() }
        view.onDraftChange = { [weak model] draft in
            model?.typedDraft = draft
            model?.lastLocalEdit = MonotonicStamp()
        }
        view.restore(model.typedDraft)
        view.appliedFieldSerial = model.fieldSerial
        view.onKey = { [weak model] usage, down, flags in
            model?.handleHardwareKey(usage, down: down, flags: flags)
        }
        return view
    }

    /// A text view has no height SwiftUI will hold it to, so it is computed from content, bounded so it grows the bar and not into the picture.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: KeyboardTypingView,
        context: Context
    ) -> CGSize? {
        let width = proposal.width ?? uiView.intrinsicContentSize.width
        guard width > 0 else { return nil }
        let needed = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        ).height
        return CGSize(
            width: width,
            height: min(
                max(needed, uiView.oneLineHeight),
                uiView.maximumHeight
            )
        )
    }

    func updateUIView(_ view: KeyboardTypingView, context: Context) {
        // Read here, not at construction, because the mode is switchable while the keyboard is up: in keycode mode a correction would arrive as keys for a word nobody typed.
        view.isLarge = isLarge
        let autocorrects = model.keyboardMode == .unicode
        view.autocorrectionType = autocorrects ? .yes : .no
        if view.appliedFieldSerial != model.fieldSerial {
            view.appliedFieldSerial = model.fieldSerial
            view.apply(model.typedDraft, selection: model.draftSelection)
        } else if view.text != model.typedDraft, view.markedTextRange == nil {
            view.restore(model.typedDraft)
        }
        if isFocused, !view.isFirstResponder {
            // A beat, because the binding is set in the same runloop turn the view is installed in, and `becomeFirstResponder` with no window yet is a silent no-op.
            DispatchQueue.main.async { view.becomeFirstResponder() }
        } else if !isFocused, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }
}

