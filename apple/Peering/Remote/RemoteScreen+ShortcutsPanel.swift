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
        HStack(alignment: .bottom, spacing: 8) {
            panelKey("delete.backward", label: String(localized: "Delete"), width: 64) { model.handleBackspace() }
            panelKey("return", label: String(localized: "Enter"), width: 64) { model.pressReturn() }
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                panelKey("chevron.up", label: String(localized: "Up arrow")) { sendKey(keyCode: 126) }
                HStack(spacing: 6) {
                    panelKey("chevron.left", label: String(localized: "Left arrow")) { sendKey(keyCode: 123) }
                    panelKey("chevron.down", label: String(localized: "Down arrow")) { sendKey(keyCode: 125) }
                    panelKey("chevron.right", label: String(localized: "Right arrow")) { sendKey(keyCode: 124) }
                }
            }
        }
    }

    private func panelKey(
        _ icon: String,
        label: String,
        width: CGFloat = 52,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: width, height: 40)
                .glassSurface(in: RoundedRectangle(cornerRadius: 9, style: .continuous), interactive: true)
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(RailButtonStyle(scale: 0.86, haptic: true))
        .accessibilityLabel(label)
    }

    func arrowStrip(withReturn: Bool = true) -> some View {
        HStack(spacing: 4) {
            compactKeyButton(icon: "chevron.left", keyCode: 123)
                .accessibilityLabel("Left arrow")
            compactKeyButton(icon: "chevron.up", keyCode: 126)
                .accessibilityLabel("Up arrow")
            compactKeyButton(icon: "chevron.down", keyCode: 125)
                .accessibilityLabel("Down arrow")
            compactKeyButton(icon: "chevron.right", keyCode: 124)
                .accessibilityLabel("Right arrow")
            if withReturn {
                compactKeyButton(icon: "return", keyCode: 36) { model.pressReturn() }
                    .accessibilityLabel("Enter")
            }
            // Through the model rather than as a bare keycode, so the typed preview loses the
            // character with the Mac's own line: sent directly, the Mac deleted and the preview
            // kept what it had, which is a bar showing text that no longer exists anywhere.
            compactCapButton(icon: "delete.backward") { model.handleBackspace() }
                .accessibilityLabel("Delete")
        }
    }
}
