import RemoteCore
import SwiftUI

/// The screen view's shortcuts panel, for the trackpad: the same sets, modifier bar and keys, sent to the Mac through the dock.
struct RemoteDockShortcutsPanel: View {
    @Environment(SessionModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            ShortcutSets(
                application: nil,
                functionKeys: AnyView(FunctionKeyGrid(
                    sendKey: { sendKey($0) },
                    sendAction: { code in
                        model.send(.keyDown(keyCode: code, modifiers: .topRowAction))
                        model.send(.keyUp(keyCode: code, modifiers: .topRowAction))
                    }
                ))
            )
            ModifierBar(large: true)
            ShortcutArrowCluster(
                sendKey: { sendKey($0) },
                onDelete: { model.handleBackspace() },
                onEnter: { model.pressReturn() }
            )
        }
        .padding(10)
    }

    private func sendKey(_ keyCode: UInt16) {
        let modifiers = model.latchedModifiers
        model.send(.keyDown(keyCode: keyCode, modifiers: modifiers))
        model.send(.keyUp(keyCode: keyCode, modifiers: modifiers))
    }
}
