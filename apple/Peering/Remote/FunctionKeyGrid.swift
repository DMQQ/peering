import RemoteCore
import SwiftUI
import UIKit

struct FunctionKeyGrid: View {
    let sendKey: (UInt16) -> Void
    let sendAction: (UInt16) -> Void

    @State private var fnLatched = false

    /// F5 and F6 have no action here: dictation and Do Not Disturb cannot be posted from outside.
    private static let icons: [String?] = [
        "sun.min", "sun.max", "rectangle.3.group", "magnifyingglass", nil, nil,
        "backward", "playpause", "forward", "speaker.slash", "speaker.wave.1", "speaker.wave.3",
    ]

    var body: some View {
        LazyVGrid(columns: ShortcutSets.columns, spacing: 8) {
            Button {
                fnLatched.toggle()
            } label: {
                Text("fn")
                    .font(.system(size: 15, weight: .medium))
                    .keyChip()
                    .background(
                        fnLatched ? ColorPalette.selectedFill : .clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
            }
            .buttonStyle(RailButtonStyle(scale: 0.86, haptic: true))
            .accessibilityLabel("Function keys")
            .accessibilityAddTraits(fnLatched ? .isSelected : [])

            ForEach(0..<12, id: \.self) { index in
                let code = MediaKey.functionKeyCodes[index]
                let icon = Self.icons[index]
                Button {
                    if !fnLatched, icon != nil { sendAction(code) } else { sendKey(code) }
                } label: {
                    VStack(spacing: 2) {
                        if !fnLatched, let icon {
                            Image(systemName: icon)
                                .font(.system(size: 15, weight: .medium))
                        }
                        Text("F\(index + 1)")
                            .font(.system(size: fnLatched || icon == nil ? 15 : 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(fnLatched || icon == nil ? ColorPalette.ink : ColorPalette.ink.opacity(0.55))
                    }
                    .keyChip()
                }
                .buttonStyle(RailButtonStyle(scale: 0.86, haptic: true))
                .accessibilityLabel("F\(index + 1)")
            }
        }
    }
}
