import SwiftUI

/// The one look of a text input that sits at the bottom of a screen: a 48 point glass capsule holding the field, with round buttons beside it. The file search, the terminal command line and the chat composer all use it, so a field means the same thing wherever it is.
enum InputBar {
    static let height: CGFloat = 48
}

struct InputCapsule<Content: View>: View {
    /// Bottom for a field that grows by lines, so its buttons stay on the last one.
    var alignment: VerticalAlignment = .center
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: alignment, spacing: 8) {
            content
        }
        .padding(.horizontal, 14)
        .frame(minHeight: InputBar.height)
        .glassSurface(in: RoundedRectangle(cornerRadius: InputBar.height / 2, style: .continuous))
    }
}

/// The send button of an input: white when there is something to send, quiet when there is not.
struct InputSendButton: View {
    var symbol = "arrow.up"
    let isEnabled: Bool
    /// False for Stop, which is an action to take, not the main thing to do.
    var filled = true
    var label: LocalizedStringKey = "Send"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(!isEnabled ? .white.opacity(0.35) : (filled ? ColorPalette.onInk : .white))
                .frame(width: InputBar.height, height: InputBar.height)
                .background(Circle().fill(!isEnabled ? Color.white.opacity(0.1) : (filled ? ColorPalette.ink : Color.white.opacity(0.16))))
                .contentShape(Circle())
        }
        .buttonStyle(RailButtonStyle(scale: 0.92))
        .disabled(!isEnabled)
        .animation(Motion.tap, value: isEnabled)
        .accessibilityLabel(label)
    }
}

extension View {
    /// The margins every bottom input keeps from the screen's edges and from what is above it.
    func inputBarMargins() -> some View {
        padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .background(Color.black)
    }
}
