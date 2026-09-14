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
