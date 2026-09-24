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

/// An invisible view that owns the keyboard.
///
/// Both keyboard modes route through one view because iOS gives them through different
/// doors, and a client that opened only one of them would be unable to type in the other:
///
/// - The **software** keyboard delivers `UIKeyInput` callbacks — `insertText` and
///   `deleteBackward` — which carry characters rather than keys.
/// - A **hardware** keyboard delivers `UIPress` objects through the responder chain, which
///   carry `UIKeyboardHIDUsage` and the modifier flags with them.
final class KeyboardCaptureView: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onDeleteBackward: (() -> Void)?
    var onKey: ((UIKeyboardHIDUsage, Bool, UIKeyModifierFlags) -> Void)?

    /// Set by the SwiftUI wrapper so the two modes can behave differently. When keycode mode
    /// is on, `insertText` is still delivered — the wrapper turns it into key presses.
    var isHardwareKeycodeMode = false

    override var canBecomeFirstResponder: Bool { true }
    override var canResignFirstResponder: Bool { true }

    // Always "has text" so the software keyboard keeps its backspace key available even when
    // the field is empty. Without it, backspace disappears the moment the user clears what
    // they typed, which is exactly when they want it.
    var hasText: Bool { true }

    func insertText(_ text: String) {
        onText?(text)
    }

    func deleteBackward() {
        onDeleteBackward?()
    }

    var keyboardType: UIKeyboardType = .default
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            handled = true
            onKey?(key.keyCode, true, key.modifierFlags)
        }
        // Hardware keys are swallowed whatever the mode: left to `super`, they would beep,
        // scroll the sheet, or dismiss the view — none of which the user asked for.
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

/// The keyboard's text, held by a field rather than by nothing.
///
/// **Because autocorrection, prediction and dictation are the text system's, and the text system
/// needs a document to offer them to.** The view above is a keyboard with no text behind it: iOS
/// gives it no suggestions, and its `autocorrectionType` is a property nothing reads. Unicode-mode
/// typing is held here instead — a real field, kept out of sight — and what the Mac is told is what
/// the field just did, character for character, including the replacements the system makes on its
/// own account: "teh" arriving as "the" is this working rather than a fault.
///
/// Invisible on purpose. The user is typing into the Mac, and everything worth seeing about that is
/// in the picture: the Mac's own text, the Mac's own caret. What this feeds is the suggestion bar
/// above the keyboard and the app's own typed preview, which is where the caret for this belongs.
final class KeyboardTypingView: UITextField, UITextFieldDelegate {
    var onType: ((String) -> Void)?
    var onDelete: ((Int) -> Void)?
    var onKey: ((UIKeyboardHIDUsage, Bool, UIKeyModifierFlags) -> Void)?
    var onReturn: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        delegate = self
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
        // Nothing is drawn: not the text, not the caret, and no background that would show through
        // the picture. `isHidden` would be the obvious way and is the one thing that cannot be
        // used, because a hidden view can never become first responder.
        textColor = .clear
        tintColor = .clear
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not built from a nib") }

    /// Sends the edit rather than describing it, and then lets the field do it.
    ///
    /// **The field has to keep the text.** It is the document autocorrection reads, so refusing the
    /// change to keep the buffer empty would be refusing the feature; and this is also the one place
    /// the system's own edits are visible — a correction arrives here as a replacement, which is how
    /// it can be said to the Mac as what it is: the old word's characters deleted, the new word typed.
    func textField(
        _ textField: UITextField,
        shouldChangeCharactersIn range: NSRange,
        replacementString string: String
    ) -> Bool {
        // Counted in characters, because a backspace on the Mac removes one of those: the range
        // arrives in UTF-16 units, where an emoji is two of them and one of these.
        let replaced = ((textField.text ?? "") as NSString).substring(with: range).count
        if replaced > 0 { onDelete?(replaced) }
        if !string.isEmpty { onType?(string) }
        return true
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        // The line is committed on the Mac, so the buffer that fed the suggestions is finished with:
        // kept, the next word's correction would be spelled against the last one's.
        reset()
        onReturn?()
        return false
    }

    /// Empties the buffer without telling the Mac anything, which is right in both cases it is
    /// called: what the buffer held has already been sent, and a Return has just committed it.
    func reset() {
        text = ""
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

/// The unicode-mode wrapper: the same job as ``KeyboardCapture`` over a field that holds text.
struct KeyboardTypingCapture: UIViewRepresentable {
    let model: SessionModel
    @Binding var isFocused: Bool

    func makeUIView(context: Context) -> KeyboardTypingView {
        let view = KeyboardTypingView()
        view.onType = { [weak model] text in model?.handleTypedText(text) }
        view.onDelete = { [weak model] count in
            // One at a time, because that is what the Mac hears either way and what the bar's own
            // preview undoes: a correction that replaced a word drops exactly that word's characters.
            for _ in 0..<count { model?.handleBackspace() }
        }
        view.onReturn = { [weak model] in model?.pressReturn() }
        view.onKey = { [weak model] usage, down, flags in
            model?.handleHardwareKey(usage, down: down, flags: flags)
        }
        return view
    }

    func updateUIView(_ view: KeyboardTypingView, context: Context) {
        if isFocused, !view.isFirstResponder {
            // The same beat the other wrapper waits, for the same reason: a `becomeFirstResponder`
            // on a view with no window yet is a silent no-op, so the keyboard would never appear.
            DispatchQueue.main.async { view.becomeFirstResponder() }
        } else if !isFocused, view.isFirstResponder {
            view.resignFirstResponder()
            // Leaving the keyboard ends the sentence the suggestions were being made for.
            view.reset()
        }
    }
}

/// SwiftUI wrapper. Zero-sized: it exists to be first responder, not to be seen.
struct KeyboardCapture: UIViewRepresentable {
    let model: SessionModel
    @Binding var isFocused: Bool

    func makeUIView(context: Context) -> KeyboardCaptureView {
        let view = KeyboardCaptureView()
        view.onText = { [weak model] text in model?.handleTypedText(text) }
        view.onDeleteBackward = { [weak model] in model?.handleBackspace() }
        view.onKey = { [weak model] usage, down, flags in
            model?.handleHardwareKey(usage, down: down, flags: flags)
        }
        return view
    }

    func updateUIView(_ view: KeyboardCaptureView, context: Context) {
        if isFocused, !view.isFirstResponder {
            // A beat, because the binding is often set from a button press in the same
            // runloop turn that the view is being installed in — and a `becomeFirstResponder`
            // on a view with no window is a silent no-op, so the keyboard would never appear.
            DispatchQueue.main.async { view.becomeFirstResponder() }
        } else if !isFocused, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }
}
