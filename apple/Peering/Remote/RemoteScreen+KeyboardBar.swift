import PeeringKit
import RemoteCore
import SwiftUI
import UIKit

extension RemoteScreen {
    /// With the keyboard up, the dock and both rails are behind it, so nothing else on this screen can
    /// be pressed. Esc is the only way out of a Mac menu or a completion list and no iOS keyboard has
    /// one; Tab is how a Mac moves focus and completes. See ``ModifierBar``.
    private var keyboardKeyRow: some View {
        HStack(spacing: 8) {
            compactCapButton(icon: "keyboard.chevron.compact.down", large: true) { model.showKeyboard = false }
                .accessibilityLabel("Hide keyboard")
            ModifierBar()
            HStack(spacing: 6) {
                compactKeyButton(icon: "escape", keyCode: 53)
                    .accessibilityLabel("Escape")
                compactKeyButton(icon: "arrow.right.to.line", keyCode: 48)
                    .accessibilityLabel("Tab")
            }
            Spacer(minLength: 8)
            // Landscape leaves about 90pt between the system keyboard and the top of the screen, which a third row does not fit in.
            if deviceIsLandscape { arrowStrip(withReturn: false) }
            compactCapButton(icon: "return", filled: true, large: true) { model.pressReturn() }
                .accessibilityLabel("Enter")
        }
    }

    var keyboardInputBar: some View {
        VStack(spacing: 8) {
            if !dictation.isListeningUI { shortcutsHandle.padding(.top, -10).padding(.bottom, -6) }
            keyboardInputRow
            if !dictation.isListeningUI {
                // Sized by the drag, so the bar grows and shrinks under the finger; the rows keep their natural height and are clipped.
                VStack(spacing: 8) {
                    keyboardKeyRow
                    if !deviceIsLandscape { arrowStrip(withReturn: false) }
                }
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if $0 > 0 { keyRowsHeight = $0 } }
                .frame(height: keyRowsHeight > 0 ? keyRowsHeight * shortcutsProgress : (shortcutsProgress == 0 ? 0 : nil), alignment: .top)
                .clipped()
                .opacity(shortcutsProgress)
                .blur(radius: (1 - shortcutsProgress) * 6)
                .allowsHitTesting(shortcutsProgress > 0.9)
                .padding(.top, -8 * (1 - shortcutsProgress))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, deviceIsLandscape ? 8 : 12)
        .glassSurface(in: RoundedRectangle(cornerRadius: ChromeMetrics.cornerRadius, style: .continuous))
        .padding(.horizontal, ChromeMetrics.edgeInset)
        .padding(.top, deviceIsLandscape ? 4 : ChromeMetrics.edgeInset)
        .offset(y: shortcutsExpanded ? 0 : max(0, shortcutsDrag * 0.5))
    }

    private var keyboardInputRow: some View {
        ZStack {
            HStack(spacing: 8) {
                if shortcutsCollapsed {
                    compactCapButton(icon: "keyboard.chevron.compact.down") { model.showKeyboard = false }
                        .accessibilityLabel("Hide keyboard")
                }
                dictationButton
                keyboardField
                if shortcutsCollapsed {
                    compactCapButton(icon: "return", filled: true) { model.pressReturn() }
                        .accessibilityLabel("Enter")
                }
            }
            .opacity(dictation.isActive ? 0 : 1)
            .allowsHitTesting(!dictation.isActive)
            switch dictation.state {
            case .listening, .finishing, .stopped:
                DictationOverlay(dictation: dictation, finish: { dictation.finish() }, cancel: { dictation.cancel() })
            case .denied, .unavailable:
                DictationNotice(denied: dictation.state == .denied) { dictation.dismissMessage() }
            case .idle:
                EmptyView()
            }
        }
        .animation(Motion.settle, value: dictation.state)
    }

    /// A handle on the bar's top edge: tap it, or drag it up or down, to show or fold the shortcut keys.
    private var shortcutsHandle: some View {
        Capsule()
            .fill(Color.white.opacity(0.32))
            .frame(width: 38, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 18)
            .contentShape(Rectangle())
            .onTapGesture { toggleShortcuts() }
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { drag in
                        // No animation: the layout must be exactly where the finger is.
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { shortcutsDrag = drag.translation.height }
                    }
                    .onEnded { drag in
                        let wasExpanded = shortcutsExpanded
                        // Settles toward where the throw was heading, past a third of the way or a quick flick.
                        let projected = shortcutsProgress - (drag.predictedEndTranslation.height - drag.translation.height) / max(keyRowsHeight, 1) * 0.4
                        withAnimation(Motion.settle) {
                            shortcutsExpanded = projected > 0.5
                            shortcutsDrag = 0
                            if !wasExpanded, !shortcutsExpanded, drag.translation.height > 70 { model.showKeyboard = false }
                        }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(shortcutsCollapsed ? String(localized: "Show shortcut keys", table: "Dictation") : String(localized: "Hide shortcut keys", table: "Dictation"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { toggleShortcuts() }
    }

    private func toggleShortcuts() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(Motion.settle) { shortcutsExpanded.toggle() }
    }

    private var dictationButton: some View {
        Button {
            dictation.start { [model] spoken in model.insertDictation(spoken) }
        } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .glassSurface(in: Circle(), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(RailButtonStyle(scale: 0.9, haptic: true))
        .accessibilityLabel(String(localized: "Dictate", table: "Dictation"))
    }

    private var keyboardField: some View {
        // **The field itself, and it is a real one.** It holds the sentence, so iOS gives it a caret
        // that can be moved and reports every edit as a range plus a replacement, which is what
        // makes correcting the middle of a line work.
        //
        // No height of its own, deliberately: the wrapper answers with the height the sentence
        // needs, so the field grows a line at a time and this bar rises with it.
        KeyboardTypingCapture(
            model: model,
            isLarge: shortcutsCollapsed,
            isFocused: Binding(
                get: { model.showKeyboard },
                set: { model.showKeyboard = $0 }
            )
        )
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            ColorPalette.backdrop.opacity(0.55),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
    }
}
