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

    /// Close, minimise and zoom as the Mac draws them, just above the window's top left corner, or inside it when the window already reaches the top of the screen.
    @ViewBuilder
    var windowControls: some View {
        if let windowID = castWindowID,
           let rect = CanvasGeometry.rect(
               normalized: NormalizedRect(x: 0, y: 0, width: 1, height: 1),
               bounds: canvasSize, pixelSize: model.capturePixelSize, zoom: effectiveZoom, pan: pan
           ),
           rect.maxY > 60, rect.minY < canvasSize.height - 60 {
            let above = rect.minY - 22 >= 64
            WindowControlDots(
                close: { model.send(.performWindowAction(windowID: windowID, action: .close)) },
                minimise: { model.send(.performWindowAction(windowID: windowID, action: .minimize)) },
                zoom: { model.send(.performWindowAction(windowID: windowID, action: .zoom)) }
            )
            .position(
                x: min(max(rect.minX + 44, 44), max(canvasSize.width - 44, 44)),
                y: above ? rect.minY - 22 : max(rect.minY, 64) + 22
            )
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }
}

private struct WindowControlDots: View {
    let close: () -> Void
    let minimise: () -> Void
    let zoom: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            dot(TileControl.red, label: String(localized: "Close window"), action: close)
            dot(TileControl.yellow, label: String(localized: "Minimise window"), action: minimise)
            dot(TileControl.green, label: String(localized: "Zoom window"), action: zoom)
        }
        .padding(.horizontal, 6)
        .glassSurface(in: Capsule())
    }

    private func dot(_ colour: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(colour)
                .frame(width: 13, height: 13)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(RailButtonStyle(scale: 0.8, haptic: true))
        .accessibilityLabel(label)
    }
}
