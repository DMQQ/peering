import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import RemoteCore
import os

extension CaptureSource {
    var description: String {
        switch self {
        case .display(let id): return "display \(id)"
        case .application(let pid): return "application \(pid)"
        case .window(let id): return "window \(id)"
        case .mosaic(let layout): return "a mosaic of \(layout.tiles.count) sources"
        }
    }
}
