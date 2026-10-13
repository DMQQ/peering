import PeeringKit
import RemoteCore
import SwiftUI

extension SessionModel {
    func addCustomMacro(_ macro: Macro) {
        customMacros.append(macro)
        saveMacros()
    }

    func removeCustomMacro(at offsets: IndexSet) {
        customMacros.remove(atOffsets: offsets)
        saveMacros()
    }

    func moveCustomMacro(from source: IndexSet, to destination: Int) {
        customMacros.move(fromOffsets: source, toOffset: destination)
        saveMacros()
    }

    func saveMacros() {
        if let data = try? JSONEncoder().encode(customMacros) {
            UserDefaults.standard.set(data, forKey: PreferenceKeys.customMacros)
        }
    }

    /// The preview stops describing anything at Return: a bar still showing the old text claims the Mac holds what it already took.
    func run(_ macro: Macro) {
        Analytics.featureUsed(.macro)
        // Down then up, never coalesced: a dropped release leaves the Mac holding a modifier.
        // Latched modifiers ride along: ⌃ held turns the ⌘C chip into ⌃⌘C.
        let modifiers = macro.modifiers.union(latchedModifiers)
        send(.keyDown(keyCode: macro.keyCode, modifiers: modifiers))
        send(.keyUp(keyCode: macro.keyCode, modifiers: modifiers))
    }

    // MARK: - Custom macros

}
