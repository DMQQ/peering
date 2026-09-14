import SwiftUI
import WidgetKit

@main
struct PeeringWidgetBundle: WidgetBundle {
    var body: some Widget {
        QuickConnectWidget()
        SessionLiveActivity()
    }
}
