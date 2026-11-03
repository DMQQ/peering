import PeeringKit
import RemoteCore
import SwiftUI
import UIKit

/// Members are `internal` because `private` is file-scoped and state and gestures live in both files.
extension RemoteScreen {
    static let pausedCardDelay: Duration = .seconds(2)

    // MARK: - Picture

    private var returningMosaic: CGImage? {
        guard transition?.carry?.carriesOutOfArrangement == false else { return nil }
        return model.renderer.mosaicSnapshot
    }

    var video: some View {
        // No `scaleEffect` or `offset`: placement is a layer transform inside the view, so a pan cannot trail the finger.
        VideoLayerView(
            renderer: model.renderer,
            pictureSize: model.capturePixelSize ?? .zero,
            zoom: effectiveZoom,
            pan: pan,
            // While a transition is in flight the frozen layer has its own animated placement; at rest the two are equal, so the cross-fade lands without a jump.
            stillZoom: transition?.zoom ?? effectiveZoom,
            stillPan: transition?.pan ?? pan,
            showsStill: transition != nil,
            stillPicture: model.renderer.stillPicture,
            backdropPicture: returningMosaic,
            backdropZoom: returningMosaic.map {
                pictureScale.base(pixelSize: CGSize(width: $0.width, height: $0.height), in: canvasSize)
            } ?? 1
        )
            .ignoresSafeArea()
            // The bar's insertion animates the safe area this view ignores, and the hosted layer
            // glided with it, so the picture moved a little each time the keyboard came or went.
            .transaction { $0.disablesAnimations = true }
            // Not at once: every reconnect is ready a moment before its first picture, and the card would flash over each one.
            .task(id: model.phase == .ready && !model.isVideoStreaming) {
                streamLooksPaused = false
                guard model.phase == .ready, !model.isVideoStreaming else { return }
                try? await Task.sleep(for: Self.pausedCardDelay)
                guard !Task.isCancelled else { return }
                streamLooksPaused = true
            }
            .overlay {
                // The last decoded frame stays on screen when the capture stream has stopped (source
                // closed, app quit), and a touch then lands on whatever the Mac shows at that
                // position rather than on what the phone is displaying.
                if streamLooksPaused {
                    ZStack {
                        Color.black.opacity(0.55).ignoresSafeArea()
                        VStack(spacing: 8) {
                            Image(systemName: "pause.circle.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(.white.opacity(0.85))
                            Text("Stream paused")
                                .font(.headline)
                                .foregroundStyle(.white)
                            Text(model.videoStatus)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                    }
                    .allowsHitTesting(false)
                }
            }
    }

    /// Above the gesture surface, or the surface takes the tap meant for Unlock.
    @ViewBuilder var remoteNoticeLayer: some View {
        // A sleeping screen is streaming on time and entirely black, so the paused card never fires for it.
        if let notice = model.remoteNotice, let message = HostNoticeText.message(for: notice), model.phase == .ready,
           !isUnlocking(notice) {
            ZStack {
                Color.black.opacity(0.72).ignoresSafeArea()
                    .allowsHitTesting(false)
                VStack(spacing: 12) {
                    Group {
                        Image(systemName: notice.symbol ?? "display.slash")
                            .font(.system(size: 44))
                            .foregroundStyle(.white.opacity(0.9))
                        Text(model.hostPlatform.adapt(HostWireText.localized(message)))
                            .font(.headline)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                        if let displayID = notice.lockedDisplayID {
                            Text(isViewing(displayID)
                                 ? "Tap Unlock to type the password."
                                 : "Its lock screen is on the display, not in what you are viewing.")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.7))
                                .multilineTextAlignment(.center)
                        }
                    }
                    // Hits pass through: an injected event is the activity a sleeping display waits for.
                    .allowsHitTesting(false)

                    if let displayID = notice.lockedDisplayID {
                        Button {
                            withAnimation(Motion.settle) { model.showLockScreen(on: displayID) }
                        } label: {
                            Label("Unlock", systemImage: "lock.open.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(ColorPalette.onInk)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 10)
                                .background(ColorPalette.ink, in: Capsule())
                        }
                        .buttonStyle(RailButtonStyle(scale: 0.94, haptic: true))
                        .padding(.top, 6)
                    }
                }
                .padding(32)
            }
        }
    }

    private func isViewing(_ displayID: UInt32) -> Bool {
        model.activeSourceID == CaptureSource.display(displayID).stableID
    }

    private func isUnlocking(_ notice: NoticePayload) -> Bool {
        guard let displayID = notice.lockedDisplayID else { return false }
        return model.showKeyboard && isViewing(displayID)
    }

    var clientCursor: some View {
        Group {
            if interactionMode.tapsReachTheMac,
               model.phase == .ready,
               // A mosaic takes no input, so a pointer drawn where the last tap landed would be false. The Mac draws the real pointer into each tile.
               !model.isShowingMosaic,
               let point = CanvasGeometry.point(
                   normalized: remoteCursor,
                   bounds: canvasSize,
                   pixelSize: model.capturePixelSize,
                   zoom: effectiveZoom,
                   pan: pan
               ) {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.9), radius: 0, x: 1.5, y: 1.5)
                    .frame(width: 32, height: 32, alignment: .topLeading)
                    .position(x: point.x + 16, y: point.y + 16)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .ignoresSafeArea()
    }

    var pictureScale: PictureScale {
        PictureScale(
            scalesToFill: scalesToFill,
            // Portrait has no margin: the pill and dock sit above and below the middle, and an arrangement's canvas is a band across it.
            inset: deviceIsLandscape ? ChromeMetrics.pictureInset : 0
        )
    }

    /// In Fill the zoom rides on top of the fill scale: with `max(zoom, fill)` a pinch did nothing until the picture was magnified past the fill.
    var effectiveZoom: CGFloat {
        pictureBaseScale * zoom
    }

    var pictureBaseScale: CGFloat {
        pictureScale.base(pixelSize: model.capturePixelSize ?? .zero, in: canvasSize)
    }

    func resetPicture() {
        zoom = 1
        pan = .zero
    }
}
