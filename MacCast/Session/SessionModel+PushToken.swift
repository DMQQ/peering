import Foundation
import MacCastKit
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

    /// This is the gate for the push half, here rather than at the Mac, which sends to a token and knows nothing else: a phone that never hands one over cannot be reached on any plan.
    /// An empty registration is sent rather than skipped: it forgets the token the Mac was given while the plan included it, which a lapsed subscription needs.
    /// Nothing is sent while the entitlement has not been read, so a subscriber is not stripped at launch.
    func sendPushToken() {
        guard let plan = storeManager.access.plan else { return }

        guard plan.includes(.terminalAlerts) else {
            for session in sessions where session.phase == .ready {
                session.wire?.sendTerminal(.registerPushToken(Data()))
            }
            return
        }

        guard let token = SessionNotifier.shared.remoteToken else { return }
        for session in sessions where session.phase == .ready {
            session.wire?.sendTerminal(.registerPushToken(token))
        }
    }
}
