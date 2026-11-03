import PeeringKit
import SwiftUI

extension SessionMode {
    var title: String {
        switch self {
        case .screen: String(localized: "Screen")
        case .workspace: String(localized: "Agents, files and terminals")
        case .remote: String(localized: "Remote")
        }
    }

    var summary: String {
        switch self {
        case .screen: String(localized: "See and control the screen, as before.")
        case .workspace: String(localized: "Work with agents, browse files and run terminals. No picture, so it uses almost no data.")
        case .remote: String(localized: "Move the mouse, click, scroll and type, without the picture. For presenting, or a slow connection.")
        }
    }

    var symbol: String {
        switch self {
        case .screen: "macwindow"
        case .workspace: "terminal"
        case .remote: "computermouse"
        }
    }
}
