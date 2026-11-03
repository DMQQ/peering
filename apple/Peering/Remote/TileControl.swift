import PeeringKit
import RemoteCore
import SwiftUI
import UIKit

struct TileControl: Identifiable {
    static let red = Color(red: 1.0, green: 0.37, blue: 0.34)
    static let yellow = Color(red: 1.0, green: 0.74, blue: 0.18)
    static let green = Color(red: 0.16, green: 0.79, blue: 0.25)

    let colour: Color
    let symbol: String
    let label: String
    let action: () -> Void
    var id: String { label }
}
