import PeeringKit
import RemoteCore
import SwiftUI
import UIKit

struct QuickAction: Identifiable {
    let chord: String
    let label: String
    let accessibilityLabel: String
    let action: () -> Void

    var id: String { chord }
}
