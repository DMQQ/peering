import MacCastKit
import RemoteCore
import SwiftUI
import UIKit

/// Latching, not momentary: a touch screen cannot hold the modifier with one hand and type with the other. Each button posts a real modifier press and release; see ``SessionModel/toggleModifier(_:keyCode:)`` for why flag bits on the next keystroke are not equivalent.
struct ModifierBar: View {
    @Environment(SessionModel.self) private var model
    var large = false

    /// Left-hand virtual keycodes: the protocol collapses left and right into one bit, so the Mac cannot observe which side is pressed.
    private static let keys: [(title: String, bit: Modifiers, code: UInt16)] = [
        ("⌘", .command, 55),
        ("⇧", .shift, 56),
        ("⌥", .option, 58),
        ("⌃", .control, 59),
    ]

    var body: some View {
        HStack(spacing: large ? 8 : 6) {
            ForEach(Self.keys, id: \.title) { key in
                let isOn = model.latchedModifiers.contains(key.bit)
                Button {
                    model.toggleModifier(key.bit, keyCode: key.code)
                } label: {
                    Text(key.title)
                        .font(.system(size: 17, weight: .medium))
                        .frame(minWidth: large ? nil : 28, idealWidth: large ? nil : 38, maxWidth: large ? nil : 38, minHeight: large ? 44 : 34, maxHeight: large ? 44 : 34)
                        .frame(maxWidth: large ? .infinity : nil)
                        .foregroundStyle(isOn ? ColorPalette.ink : Color.primary)
                        .background(isOn ? ColorPalette.selectedFill : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .glassSurface(in: RoundedRectangle(cornerRadius: 9, style: .continuous), interactive: true)
                }
                .buttonStyle(RailButtonStyle(scale: 0.86))
                .accessibilityLabel(key.title)
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        }
    }
}
