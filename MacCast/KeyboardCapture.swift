import RemoteCore
import SwiftUI
import UIKit

/// Conversions between what iOS reports and what macOS injects.
///
/// The two platforms name keys differently and neither name is the other's:
///
/// - iOS reports `UIKeyboardHIDUsage`, which is a **USB HID usage** from the Keyboard/Keypad
///   page — the number a physical keyboard sends over the wire. `A` is 4, `1` is 30.
/// - macOS injects a **virtual keycode** from `Events.h`, which is a *layout* artefact of the
///   original Mac keyboard matrix. `A` is 0, `1` is 18.
///
/// They are close enough to look interchangeable and are not: sending a HID usage where a
/// virtual keycode is expected types a plausible-looking wrong character, which is the kind
/// of bug that survives a code review. The table below is the translation, and it is the
/// reason keycode mode needs one at all.
enum KeycodeMap {
    /// A macOS virtual keycode for a HID usage, or `nil` for a key this client does not send.
    static func macOSKeycode(for usage: UIKeyboardHIDUsage) -> UInt16? {
        switch usage {
        // Letters
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

        // Digits
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

        // Punctuation
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

        // Editing and navigation
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

        // Function keys
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

    /// A macOS virtual keycode for a character, using the **US layout**.
    ///
    /// The software keyboard produces characters, not keycodes, so keycode mode needs this to
    /// be usable without a hardware keyboard. It is a US table and only a US table: iOS does
    /// not tell an app which layout the Mac is set to, so a client on an AZERTY phone typing
    /// in keycode mode will produce QWERTY positions. That is the honest limitation of
    /// sending key positions instead of text, and it is why Unicode mode is the default.
    static func macOSKeycode(forCharacter character: Character) -> UInt16? {
        // Case is carried by shift, not by the keycode: `a` and `A` are the same key. The
        // caller pairs this with ``characterNeedsShift(_:)`` to supply the modifier, because
        // a keycode alone cannot express it.
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

        // The shifted variants of the digit row and a few symbols, which the software
        // keyboard produces as characters and which have to map back to their key.
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

    /// Whether the character requires shift to be engaged on the Mac.
    ///
    /// `A`, `!` and `$` are all "the same key with shift held", so a client that sends only
    /// the keycode types `a`, `1` and `4` instead. There is no way to recover this from the
    /// keycode, which is why it is computed from the character at the one place characters
    /// become commands.
    static func characterNeedsShift(_ character: Character) -> Bool {
        if character.isUppercase { return true }
        return "!@#$%^&*()_+{}|:\"~<>?".contains(character)
    }

    /// Translates the modifier state iOS reports on a key press.
    static func modifiers(from flags: UIKeyModifierFlags) -> Modifiers {
        var modifiers: Modifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.alternate) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }
}

/// The keyboard's text, held by a field rather than by nothing.
///
/// **Because autocorrection, prediction and dictation are the text system's, and the text system
/// needs a document to offer them to.** A keyboard with no text behind it gets no suggestions, and
/// its `autocorrectionType` is a property nothing reads. Typing is held here instead, and what the Mac
/// is told is what the field just did, character for character, including the replacements the system
/// makes on its own account: "teh" arriving as "the" is this working rather than a fault.
///
/// It is also the only place on this side where a caret can be put anywhere but the end, which is what
/// makes correcting the middle of a line possible at all.
///
/// Both modes use it: the wrapper turns the edits into keycodes in keycode mode rather than into text.
final class KeyboardTypingView: UITextView, UITextViewDelegate {
    /// The face the field is set in, in one place because the bar's height is worked out from it.
    static let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    /// One line, and the most the field may grow to before it scrolls inside itself. The cap is what
    /// keeps this a bar rather than a panel; past it the text view scrolls, and it keeps the caret in
    /// view, so the newest line stays on screen.
    static var oneLineHeight: CGFloat { (font.lineHeight + 8).rounded() }
    static var maximumHeight: CGFloat { (font.lineHeight * 4 + 10).rounded() }

    var onType: ((String) -> Void)?
    var onDelete: ((Int) -> Void)?
    var onKey: ((UIKeyboardHIDUsage, Bool, UIKeyModifierFlags) -> Void)?
    var onReturn: (() -> Void)?

    /// "Typing…", because a text view has no placeholder of its own.
    private let hint = UILabel()

    init() {
        super.init(frame: .zero, textContainer: nil)
        delegate = self
        isScrollEnabled = true
        // No insets of its own, so the text sits against the well the bar draws around it. Reaching
        // `textContainer` is what puts this on TextKit 1, the compatibility path.
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0

        // The point of the field: the sentence above the keyboard, and the corrections in it.
        autocorrectionType = .yes
        // Not spelled out: terminal output is not English prose, and a red underline under a path
        // reads as a warning about the path.
        spellCheckingType = .no
        // Capitalisation stays off. This types into the Mac's own applications, and a shell prompt
        // that capitalises the first word of every command is worse than one that never does.
        autocapitalizationType = .none
        keyboardType = .default
        returnKeyType = .send

        font = Self.font
        textColor = .white
        tintColor = .white
        backgroundColor = .clear

        hint.text = "Typing…"
        hint.font = Self.font
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

    /// Sends the edit rather than describing it, and then lets the field do it.
    ///
    /// The field has to keep the text: it is the document autocorrection reads, so refusing the change
    /// would be refusing the feature. A correction arrives here as a replacement, which is how it can be
    /// said to the Mac as what it is.
    func textView(
        _ textView: UITextView,
        shouldChangeTextIn range: NSRange,
        replacementText text: String
    ) -> Bool {
        // Return is a key the Mac gets, not a newline this field keeps. **The check is on the whole
        // replacement rather than on equality with "\n"**: the system commits a pending correction and
        // the Return together, so "word\n" arrived as one edit, the newline was inserted into the field
        // and no Return was ever sent.
        if text.contains("\n") {
            let typed = text.replacingOccurrences(of: "\n", with: "")
            if !typed.isEmpty { onType?(typed) }
            reset()
            onReturn?()
            return false
        }
        // Counted in characters, because a backspace on the Mac removes one of those: the range
        // arrives in UTF-16 units, where an emoji is two of them and one of these.
        let replaced = (textView.text as NSString).substring(with: range).count
        if replaced > 0 { onDelete?(replaced) }
        if !text.isEmpty { onType?(text) }
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        hint.isHidden = !textView.text.isEmpty
    }

    /// Empties the buffer without telling the Mac anything, which is right in both cases it is
    /// called: what the buffer held has already been sent, and a Return has just committed it.
    func reset() {
        text = ""
        hint.isHidden = false
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            handled = true
            onKey?(key.keyCode, true, key.modifierFlags)
        }
        // Swallowed, exactly as the view above swallows them: a hardware key is a keycode with
        // modifiers the Mac should receive as keys, and a press left to `super` would be turned into
        // text by the text system and arrive a second time as a character.
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

/// The wrapper for the field that owns the keyboard, in both modes.
struct KeyboardTypingCapture: UIViewRepresentable {
    let model: SessionModel
    @Binding var isFocused: Bool

    func makeUIView(context: Context) -> KeyboardTypingView {
        let view = KeyboardTypingView()
        view.onType = { [weak model] text in model?.handleTypedText(text) }
        view.onDelete = { [weak model] count in
            // One at a time, because that is what the Mac hears either way and what the field's own
            // text undoes: a correction that replaced a word drops exactly that word's characters.
            for _ in 0..<count { model?.handleBackspace() }
        }
        view.onReturn = { [weak model] in model?.pressReturn() }
        view.onKey = { [weak model] usage, down, flags in
            model?.handleHardwareKey(usage, down: down, flags: flags)
        }
        return view
    }

    /// **The field's height, from what is in it.** A text view has no height of its own that SwiftUI
    /// will hold it to, and this bar has to grow as the sentence wraps rather than scroll it sideways
    /// out of view. Bounded, so it grows the bar and not into the picture.
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
                max(needed, KeyboardTypingView.oneLineHeight),
                KeyboardTypingView.maximumHeight
            )
        )
    }

    func updateUIView(_ view: KeyboardTypingView, context: Context) {
        // Per mode, and read here rather than at construction because the mode is switchable while the
        // keyboard is up: keycode mode sends keys, so a correction would arrive as keys for a word
        // nobody typed.
        let autocorrects = model.keyboardMode == .unicode
        view.autocorrectionType = autocorrects ? .yes : .no
        if isFocused, !view.isFirstResponder {
            // A beat, because the binding is set from a button press in the same runloop turn that the
            // view is being installed in, and a `becomeFirstResponder` on a view with no window yet is
            // a silent no-op, so the keyboard would never appear.
            DispatchQueue.main.async { view.becomeFirstResponder() }
        } else if !isFocused, view.isFirstResponder {
            view.resignFirstResponder()
            // Leaving the keyboard ends the sentence the suggestions were being made for.
            view.reset()
        }
    }
}

