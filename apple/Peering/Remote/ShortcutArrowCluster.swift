import SwiftUI

/// Escape, Tab, Delete and Return on the left, the arrows on the right: the keys the shortcuts panel adds to what a phone keyboard can send. The caller decides how a key is sent, so a latched modifier can be applied.
struct ShortcutArrowCluster: View {
    let sendKey: (UInt16) -> Void
    let onDelete: () -> Void
    let onEnter: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    panelKey("escape", label: String(localized: "Escape"), width: 64) { sendKey(53) }
                    panelKey("arrow.right.to.line", label: String(localized: "Tab"), width: 64) { sendKey(48) }
                }
                HStack(spacing: 6) {
                    panelKey("delete.backward", label: String(localized: "Delete"), width: 64, action: onDelete)
                    panelKey("return", label: String(localized: "Enter"), width: 64, action: onEnter)
                }
            }
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                panelKey("chevron.up", label: String(localized: "Up arrow")) { sendKey(126) }
                HStack(spacing: 6) {
                    panelKey("chevron.left", label: String(localized: "Left arrow")) { sendKey(123) }
                    panelKey("chevron.down", label: String(localized: "Down arrow")) { sendKey(125) }
                    panelKey("chevron.right", label: String(localized: "Right arrow")) { sendKey(124) }
                }
            }
        }
    }

    private func panelKey(_ icon: String, label: String, width: CGFloat = 52, action: @escaping () -> Void) -> some View {
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
}
