import PeeringKit
import RemoteCore
import SwiftUI
import UIKit

extension RemoteScreen {
    func presentLandscapeHint() {
        // The landscape half of this guard is load-bearing for the flag: nothing is marked when a
        // session comes up sideways, so a phone whose first sessions are all landscape is still owed
        // the hint and gets it the first time one comes up in portrait.
        guard !deviceIsLandscape, !hasSeenLandscapeHint else { return }
        hasSeenLandscapeHint = true

        withAnimation(Motion.settle) { showsLandscapeHint = true }

        landscapeHintTask?.cancel()
        landscapeHintTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            dismissLandscapeHint()
        }
    }

    func dismissLandscapeHint() {
        landscapeHintTask?.cancel()
        landscapeHintTask = nil
        withAnimation(Motion.settle) { showsLandscapeHint = false }
    }

    /// An app cannot read Rotation Lock, so the error handler is the only way to tell a locked phone
    /// from a working one. The card stops fading while the request is out, so the button cannot
    /// dismiss the thing it sits on.
    func rotateToLandscape() {
        landscapeHintTask?.cancel()
        landscapeHintTask = nil

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first
        else { return }

        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in
            // The handler is not guaranteed to be on the main actor, and it writes view state.
            Task { @MainActor in
                withAnimation(Motion.settle) { rotationRefused = true }
            }
        }
    }
}
