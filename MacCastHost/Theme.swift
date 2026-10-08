import SwiftUI

/// The host's palette, in the same world as the client's.
enum HostPalette {
    // MARK: Stage

    static let backdrop = Color(red: 0.04, green: 0.04, blue: 0.045)

    /// A panel resting on the stage.
    static let surface = Color.white.opacity(0.045)
    /// A row, tile or hover inside a panel. Twice the panel's own lift, so the two never read
    /// as the same surface at two sizes.
    static let raised = Color.white.opacity(0.085)

    static let stageLight = LinearGradient(
        colors: [Color.white.opacity(0.035), .clear],
        startPoint: .top,
        endPoint: .center
    )

    // MARK: Ink

    static let ink = Color.white
    static let muted = Color.white.opacity(0.62)
    /// The quietest tone that still reads: idle, absent, switched off.
    static let faint = Color.white.opacity(0.46)

    // MARK: Edges

    static let hairline = Color.white.opacity(0.08)
    static let litEdge = LinearGradient(
        colors: [Color.white.opacity(0.18), Color.white.opacity(0.04)],
        startPoint: .top,
        endPoint: .bottom
    )

    /// What the system-drawn controls are tinted with, and a trap worth writing down.
    static let controlTint = Color.primary

    // MARK: State

    /// The one colour in the app.
    static let accent = Color.blue

    /// State colours are reserved for operational feedback, never decoration.
    static let success = Color(red: 0.36, green: 0.85, blue: 0.55)
    static let caution = Color(red: 0.97, green: 0.71, blue: 0.30)
    static let danger = Color(red: 0.98, green: 0.45, blue: 0.40)

    // MARK: Measure

    static let panelRadius: CGFloat = 18
    static let controlRadius: CGFloat = 10
}

enum HostDisplayFont {
    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .serif)
    }
}

enum HostMotion {
    static let hover = Animation.spring(response: 0.24, dampingFraction: 0.86)
    static let press = Animation.spring(response: 0.18, dampingFraction: 0.78)
    static let state = Animation.spring(response: 0.36, dampingFraction: 0.88)
}

extension View {
    func hostCaption(_ color: Color = HostPalette.muted) -> some View {
        font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    func hostSwitch() -> some View {
        labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(HostPalette.accent)
    }

    func hostPanel(cornerRadius: CGFloat = HostPalette.panelRadius) -> some View {
        background(HostPalette.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(HostPalette.litEdge, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.34), radius: 16, y: 7)
    }

    /// The live stream's frame: the one object in the window that is not a panel.
    func hostPrimaryPanel(cornerRadius: CGFloat = HostPalette.panelRadius) -> some View {
        padding(3)
            .background(HostPalette.surface, in: RoundedRectangle(cornerRadius: cornerRadius + 3, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius + 3, style: .continuous)
                    .strokeBorder(HostPalette.litEdge, lineWidth: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(HostPalette.hairline, lineWidth: 1)
                    .padding(3)
            }
            .shadow(color: .black.opacity(0.5), radius: 28, y: 12)
    }
}

/// The window's primary action, and the only control that gets a fill of its own.
struct HostHostingButtonStyle: ButtonStyle {
    let isHosting: Bool

    func makeBody(configuration: Configuration) -> some View {
        HostingButtonBody(isHosting: isHosting, configuration: configuration)
    }

    /// A view rather than a modifier chain, because the outline needs to know the pointer is on
    /// it and a `ButtonStyle` has nowhere to keep that.
    private struct HostingButtonBody: View {
        let isHosting: Bool
        let configuration: Configuration

        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isHosting ? HostPalette.ink : .white)
                .background(
                    isHosting
                        ? (hovering ? HostPalette.raised : Color.clear)
                        : HostPalette.accent,
                    in: RoundedRectangle(cornerRadius: HostPalette.controlRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: HostPalette.controlRadius, style: .continuous)
                        .strokeBorder(
                            isHosting
                                ? AnyShapeStyle(HostPalette.litEdge)
                                : AnyShapeStyle(Color.white.opacity(0.22)),
                            lineWidth: 1
                        )
                }
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .shadow(
                    color: isHosting ? .clear : HostPalette.accent.opacity(configuration.isPressed ? 0.12 : 0.28),
                    radius: configuration.isPressed ? 3 : 10,
                    y: configuration.isPressed ? 1 : 5
                )
                .animation(HostMotion.press, value: configuration.isPressed)
                .animation(HostMotion.hover, value: hovering)
                .onHover { hovering = $0 }
        }
    }
}
