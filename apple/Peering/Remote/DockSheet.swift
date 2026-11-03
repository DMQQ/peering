import RemoteCore
import SwiftUI
import UIKit

struct DockSheet: Identifiable {
    let id: String
    let controls: [DockControl]
    let edits: [QuickAction]
    var applicationName: String? = nil

    var spokenName: String {
        if let applicationName { return String(localized: "\(applicationName) shortcuts") }
        return controls.isEmpty ? String(localized: "Editing shortcuts") : String(localized: "Dock controls")
    }
}
