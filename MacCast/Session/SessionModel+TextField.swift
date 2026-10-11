import Foundation
import MacCastKit
import Observation
import RemoteCore
import SwiftUI
import UIKit
import WidgetKit
import os

extension SessionModel {
    func textFocusChanged(_ focus: TextFocus) {
        let enabled = UserDefaults.standard.object(forKey: PreferenceKeys.opensKeyboardForTextFields) as? Bool ?? true
        typedDraft = ""
        pendingField = nil
        fieldCaret = nil
        guard enabled, !isObserving, !isShowingMosaic, !isPanelOpen else { return }
        if focus.isEditable {
            guard !showKeyboard else { return }
            showKeyboard = true
            keyboardOpenedByFocus = true
        } else if keyboardOpenedByFocus {
            showKeyboard = false
        }
    }

    func fieldStateChanged(_ state: FieldState) {
        fieldCaret = state.caret
        guard state.text != nil else { return }
        pendingField = state
        applyPendingFieldWhenQuiet()
    }

    private func applyPendingFieldWhenQuiet() {
        guard let state = pendingField, let text = state.text else { return }
        let wait = Self.fieldSettleTime - Date().timeIntervalSince(lastLocalEdit)
        if wait > 0 {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                self?.applyPendingFieldWhenQuiet()
            }
            return
        }
        pendingField = nil
        typedDraft = text
        let selection = state.selection(inTextOfLength: (text as NSString).length)
        draftSelection = NSRange(location: selection.location, length: selection.length)
        fieldSerial += 1
    }

    static let fieldSettleTime: TimeInterval = 0.8
}
