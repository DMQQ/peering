import PeeringKit
import RemoteCore
import SwiftUI

extension RemoteScreen {
    /// The window being cast, when the Mac is showing one window and nothing else.
    private var castWindowID: UInt32? {
        guard model.phase == .ready, interactionMode == .control,
              let source = model.activeSourceID, source.hasPrefix("window:")
        else { return nil }
        return UInt32(source.dropFirst("window:".count))
    }

    /// Close, minimise and zoom as the Mac draws them, just above the window's top left corner. Only a window that already reaches the top of the screen has no room above, and gets them inside.
    @ViewBuilder
    var windowControls: some View {
        if let windowID = castWindowID,
           let rect = CanvasGeometry.rect(
               normalized: NormalizedRect(x: 0, y: 0, width: 1, height: 1),
               bounds: canvasSize, pixelSize: model.capturePixelSize, zoom: effectiveZoom, pan: pan
           ),
           rect.maxY > 60, rect.minY < canvasSize.height - 60 {
            let above = rect.minY >= 40
            let leading = min(max(rect.minX, 8), max(canvasSize.width - 120, 8))
            WindowControlDots(
                appName: model.catalog?.descriptor(for: .window(windowID))?.subtitle,
                maximumNameWidth: canvasSize.width - leading - 16 - 92,
                close: { model.send(.performWindowAction(windowID: windowID, action: .close)) },
                minimise: { model.send(.performWindowAction(windowID: windowID, action: .minimize)) },
                zoom: { model.send(.performWindowAction(windowID: windowID, action: .zoom)) }
            )
            .fixedSize()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, leading)
            .padding(.top, above ? rect.minY - 38 : max(rect.minY, 40) + 6)
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomLeading)))
        }
    }
}

private struct WindowControlDots: View {
    let appName: String?
    let maximumNameWidth: CGFloat
    let close: () -> Void
    let minimise: () -> Void
    let zoom: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 0) {
                dot(TileControl.red, label: String(localized: "Close window"), action: close)
                dot(TileControl.yellow, label: String(localized: "Minimise window"), action: minimise)
                dot(TileControl.green, label: String(localized: "Zoom window"), action: zoom)
            }
            if let appName, !appName.isEmpty {
                Text(appName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .frame(maxWidth: max(maximumNameWidth, 40), alignment: .leading)
                    .padding(.trailing, 6)
            }
        }
        .padding(.horizontal, 4)
        .glassSurface(in: Capsule())
    }

    private func dot(_ colour: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            GlassDot(colour: colour)
                .frame(width: 24, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(RailButtonStyle(scale: 0.8, haptic: true))
        .accessibilityLabel(label)
    }
}

/// A bead of coloured glass: lit from above, clear at the rim, with a bright highlight on top and a soft glow under it.
private struct GlassDot: View {
    let colour: Color
    private let size: CGFloat = 14

    var body: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [colour.opacity(0.95), colour.opacity(0.55)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .overlay {
                Circle().strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.8
                )
            }
            .overlay(alignment: .top) {
                Ellipse()
                    .fill(LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .frame(width: size * 0.62, height: size * 0.4)
                    .padding(.top, 1.2)
            }
            .frame(width: size, height: size)
            .shadow(color: colour.opacity(0.5), radius: 3, y: 1)
    }
}
