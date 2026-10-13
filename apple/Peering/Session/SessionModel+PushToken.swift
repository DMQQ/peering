import Foundation
import PeeringKit
import Observation
import RemoteCore
import SwiftUI
import UIKit
import WidgetKit
import os

extension SessionModel {
    /// Read through the notifier rather than copied, as it is written from an app-delegate callback.
    var pushRegistration: String? {
        if notifier.remoteToken != nil { return String(localized: "Yes") }
        return notifier.remoteTokenFailure
    }

    func refreshNotificationAuthorization() async {
        notificationsAuthorized = await notifier.refreshAuthorization()
    }

    /// The Mac sends to a token and knows nothing else: a phone that never hands one over cannot be reached.
    func sendPushToken() {
        guard let token = SessionNotifier.shared.remoteToken else { return }
        for session in sessions where session.phase == .ready {
            session.wire?.sendTerminal(.registerPushToken(token))
        }
    }
}
