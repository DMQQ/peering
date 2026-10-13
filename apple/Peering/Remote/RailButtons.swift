import PeeringKit
import RemoteCore
import SwiftUI
import UIKit

/// Split out because a `Menu` in a rail takes a label rather than a button; one view means the two cannot disagree.
struct RailButtonLabel: View {
    let icon: String
    let label: String
    var selected: Bool = false
    var enabled: Bool = true

    @Environment(\.controlIsPressed) private var isPressed: Bool

    private static let minimumWidth: CGFloat = ChromeMetrics.panelWidth - 8

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(selected ? ColorPalette.ink : (enabled ? Color.primary : Color.secondary))
            Text(label)
                .font(.system(size: 9, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? ColorPalette.ink : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(minWidth: Self.minimumWidth, maxWidth: .infinity)
        .frame(height: ChromeMetrics.buttonHeight)
        // A stadium like the rail it sits in: the rail's ends and the button's ends are the only two curves on screen and must match.
        .background {
            // The press is drawn over the state so a selected control flashes without losing the blue that says it is on.
            Capsule()
                .fill(selected ? ColorPalette.selectedFill : Color.clear)
                .overlay { Capsule().fill(isPressed ? ColorPalette.pressedFill : Color.clear) }
        }
        .animation(Motion.tap, value: selected)
        .animation(Motion.tap, value: enabled)
    }
}

/// Return is the most pressed key on a remote desktop, so it sits under the hand holding the phone.
struct QuickKeyButton: View {
    let icon: String
    let label: String
    var size: CGFloat = ChromeMetrics.quickKeySize
    /// The return arrow and back chevron are both small glass discs in one corner, so a word tells them apart; `label` stays as the spoken name.
    var caption: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: icon)
                    .font(.system(size: size / 3, weight: .medium))
                if let caption {
                    Text(caption)
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .frame(width: size, height: size)
                .glassSurface(in: Capsule(), interactive: true)
        }
        .buttonStyle(RailButtonStyle(haptic: true))
        .accessibilityLabel(label)
    }
}

/// Published by ``RailButtonStyle``, the only thing that sees a press, and read by the label, which knows its own shape.
private struct ControlPressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var controlIsPressed: Bool {
        get { self[ControlPressedKey.self] }
        set { self[ControlPressedKey.self] = newValue }
    }
}

/// A `.plain` button on iOS shows no sign it was hit, which on a translucent panel over live video makes a tap feel dead.
struct RailButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.9

    /// Off by default: elsewhere a tap is answered by a visible change and buzzing is noise. The session chrome turns it on because its work happens on the other machine.
    var haptic: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.controlIsPressed, configuration.isPressed)
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: configuration.isPressed) { _, pressed in
                haptic && pressed
            }
    }
}

struct RailButton: View {
    let icon: String
    let label: String
    var selected: Bool = false
    var enabled: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            RailButtonLabel(icon: icon, label: label, selected: selected, enabled: enabled)
        }
        .buttonStyle(RailButtonStyle(haptic: true))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The chord is the primary mark: shown as the shortcut text it scans faster than a glyph and carries over from the physical keyboard.
struct ShortcutRailButton: View {
    let chord: String
    let label: String
    let accessibilityLabel: String
    var action: () -> Void

    @Environment(\.controlIsPressed) private var isPressed: Bool

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(chord)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(minWidth: ChromeMetrics.panelWidth - 8, maxWidth: .infinity)
            .frame(height: ChromeMetrics.buttonHeight)
            .contentShape(Capsule())
            .background(isPressed ? ColorPalette.pressedFill : Color.clear, in: Capsule())
        }
        .buttonStyle(RailButtonStyle(haptic: true))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Sends \(chord) to the Mac")
    }
}

struct ControlRail<Content: View>: View {
    private let content: Content
    private let maxHeight: CGFloat

    init(maxHeight: CGFloat = .infinity, @ViewBuilder content: () -> Content) {
        self.maxHeight = maxHeight
        self.content = content()
    }

    var body: some View {
        // Ordered most-used first: anything the user has to scroll to is by definition not what they reach for most.
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: ChromeMetrics.buttonGap) {
                content
            }
            .padding(.vertical, ChromeMetrics.railPadding)
            .padding(.horizontal, ChromeMetrics.railSidePadding)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: ChromeMetrics.panelWidth)
        .frame(maxHeight: maxHeight)
        // A stadium, not a rounded rectangle: at this width a 20pt radius reads as neither pill nor rectangle, and the rail is the only panel taller than wide. Other panels keep `cornerRadius`.
        .glassSurface(in: Capsule())
        // Clipped to the same capsule: `glassSurface(in:)` only shapes the background, so content scrolling past a short rail's end shows through the transparent curve.
        .clipShape(Capsule())
    }
}
