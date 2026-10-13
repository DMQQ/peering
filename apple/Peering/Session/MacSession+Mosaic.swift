import Foundation
import PeeringKit
import Observation
import RemoteCore
import SwiftUI
import UIKit
import os

extension MacSession {
    var mosaicLayout: MosaicLayout? {
        MosaicGrid.layout(
            choices: mosaicChoices,
            viewport: mosaicViewport,
            tileAspect: mosaicTileAspect
        )
    }

    /// The ask is built before ``mosaicChoices`` holds it, so shaping must be a function of the choices being asked for: read from the session, the same arrangement came out a different shape depending on which door asked (a restore used the fallback aspect). The median ignores one odd window; sources the catalogue cannot describe are left out.
    func tileAspect(for choices: [MosaicChoice]) -> Double {
        let aspects = choices
            .compactMap { catalog?.descriptor(for: $0.source)?.pixelSize }
            .filter { $0.width > 0 && $0.height > 0 }
            .map { Double($0.width / $0.height) }
            .sorted()
        guard !aspects.isEmpty else { return MosaicGrid.windowAspect }
        // Clamped: a 40-pixel strip of a window is capturable but a bad thing to build a grid from.
        return min(max(aspects[aspects.count / 2], 0.5), 3.0)
    }

    /// The shape comes from the interface and the pixels from the screen: `bounds` does not change when the phone turns, only which number is the width, and iOS takes about two seconds to say so. Read from the window scene, not `UIScreen.main`.
    var mosaicViewport: CGSize {
        guard let scene = DeviceScene.window else {
            return CGSize(width: 1280, height: 720)
        }
        let bounds = scene.screen.bounds
        let scale = scene.screen.scale
        let longer = max(bounds.width, bounds.height) * scale
        let shorter = min(bounds.width, bounds.height) * scale
        return DeviceScene.isLandscape
            ? CGSize(width: longer, height: shorter)
            : CGSize(width: shorter, height: longer)
    }
}
