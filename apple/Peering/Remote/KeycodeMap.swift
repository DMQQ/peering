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
        // `Modifiers` bitmask has no way to distinguish them, see `InputEncoding`.
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
