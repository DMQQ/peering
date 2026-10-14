import Foundation
import PeeringKit

extension MacSession {
    /// Only for the Mac on screen: a background Mac's slow link is not what the person is looking at.
    func warnIfConnectionIsVeryBad(_ milliseconds: Double) {
        guard badConnectionWarning.shouldWarn(milliseconds: milliseconds), isActive else { return }
        InAppBanner.shared.post(InAppBannerItem(
            symbol: "wifi.exclamationmark",
            title: String(localized: "Your connection is very bad"),
            summary: String(localized: "Ping is \(Int(milliseconds)) ms"),
            body: hostPlatform.adapt(String(localized: "The picture and your input will lag until the connection to your Mac improves.")),
            needsYou: false,
            target: nil
        ))
    }
}
