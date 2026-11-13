import PeeringKit
import SwiftUI

extension SessionSurface {
    @ViewBuilder
    var remoteDock: some View {
        if let session = model.activeSession, session.modeResolved, session.mode == .remote {
            RemoteDockView()
                .transition(.opacity)
        }
    }
}
