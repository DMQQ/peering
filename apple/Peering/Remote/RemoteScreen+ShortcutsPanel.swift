import RemoteCore
import SwiftUI
import UIKit

extension RemoteScreen {
    var shortcutsPanel: some View {
        VStack(spacing: 8) {
            if model.showKeyboard, !model.typedPreview.isEmpty {
                HStack {
                    Text(model.typedPreview)
                        .font(.system(.footnote, design: .monospaced))
                        .lineLimit(1)
                        // Head-truncate so the most-recently-typed characters stay visible
                        // when the preview is wider than the available space.
                        .truncationMode(.head)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            ShortcutSets(
                application: activeApplicationProfile.map { profile in
                    (profile.name, AnyView(applicationActions(profile)))
                },
                functionKeys: AnyView(functionKeyRow)
            )

            ModifierBar(large: true)

            arrowCluster
        }
        .padding(10)
    }

    var activeApplicationProfile: ApplicationProfile? {
        guard let activeSourceID = model.activeSourceID else { return nil }
        let bundleID = model.catalog?.all.first { $0.id == activeSourceID }?.bundleIdentifier
        return ApplicationActions.profile(forBundleID: bundleID)
    }

    func applicationActions(_ profile: ApplicationProfile) -> some View {
        LazyVGrid(columns: ShortcutSets.columns, spacing: 8) {
                ForEach(profile.actions) { action in
                    Button {
                        sendKey(keyCode: action.keyCode, modifiers: action.modifiers)
                    } label: {
                        Text(action.title)
                            .font(.system(size: 15, weight: .medium))
                            .padding(.horizontal, 8)
                            .keyChip()
                    }
                    .buttonStyle(RailButtonStyle(scale: 0.86, haptic: true))
                    // The keystroke is the visible label and the reason is not, so the
                    // reason is what gets spoken.
                    .accessibilityLabel(action.detail)
                }
        }
    }

    /// Two homes, because the phone holds no text: the sentence being typed is on the Mac, so sending
    /// the caret back through it is the only way to edit the middle of a line.
    /// F1 to F12, which a phone keyboard cannot send. Through ``sendKey(keyCode:modifiers:)``, so a
    /// latched modifier applies: ⌘ then F5 is VoiceOver, ⌃ then F2 the menu bar.
    var functionKeyRow: some View {
        FunctionKeyGrid(
            sendKey: { sendKey(keyCode: $0) },
            sendAction: { code in
                model.send(.keyDown(keyCode: code, modifiers: .topRowAction))
                model.send(.keyUp(keyCode: code, modifiers: .topRowAction))
            }
        )
    }

    var arrowCluster: some View {
        ShortcutArrowCluster(
            sendKey: { sendKey(keyCode: $0) },
            onDelete: { model.handleBackspace() },
            onEnter: { model.pressReturn() }
        )
    }
}
