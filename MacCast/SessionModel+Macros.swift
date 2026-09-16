import RemoteCore
import SwiftUI

/// Saved macros, kept in the defaults.
///
/// An extension on the model rather than a type of its own: this state is the
/// model's, and splitting the *type* would mean either exposing it or copying it.
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
            UserDefaults.standard.set(data, forKey: Self.customMacrosKey)
        }
    }

    /// Return, and the typed preview goes with it.
    ///
    /// The preview is the line the Mac has been sent since it was last emptied, and a Return is
    /// the point at which that stops describing anything: the line is committed, the field it went
    /// into has moved on, and a bar still showing the old text claims the Mac is holding something
    /// it has already taken.
    func run(_ macro: Macro) {
        // Down then up, in that order, and never coalesced — a macro whose release was
        // dropped would leave the Mac holding a modifier with no way to clear it from here.
        send(.keyDown(keyCode: macro.keyCode, modifiers: macro.modifiers))
        send(.keyUp(keyCode: macro.keyCode, modifiers: macro.modifiers))
    }

    // MARK: - Custom macros

}
