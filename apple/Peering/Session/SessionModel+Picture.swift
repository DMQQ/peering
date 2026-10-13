import Foundation
import MacCastKit
import Observation
import RemoteCore
import SwiftUI
import UIKit
import WidgetKit
import os

extension SessionModel {
    var autoQualityPath: AutoQualityPolicy.Path {
        switch connectionPath {
        case .lan: return .lan
        case .relay: return .relay
        case .direct, nil: return .direct
        }
    }

    var activeSourceTitle: String? { activeSession?.activeSourceTitle }

    var capturePixelSize: CGSize? { activeSession?.capturePixelSize }

    var capturePointSize: CGSize {
        activeSession?.capturePointSize ?? CGSize(width: 1512, height: 982)
    }

    func pictureIdentity(of config: VideoStreamConfig) -> PictureIdentity {
        PictureIdentity.forStream(
            config,
            catalog: catalog,
            source: mosaicLayout.map { CaptureSource.mosaic($0) }
        )
    }
}
