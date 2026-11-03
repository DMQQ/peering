import PeeringKit
import StoreKit
import SwiftUI
import UIKit

extension OnboardingView {
    static let pages: [Page] = [
        Page(
            content: .feature(icon: "macwindow", screenshot: "AppMac"),
            title: String(localized: "Your Mac needs the other half"),
            body: """
                A small Peering app on your Mac shares its screen and turns your taps into clicks. \
                It is a download rather than an App Store app, and its code is public.
                """,
            device: .mac(companion: "AppConnect"),
            chips: [
                FloatingChip(symbol: "checkmark.circle", title: String(localized: "One-time setup"), alignment: .leading, y: 0.2),
                FloatingChip(symbol: "person.crop.circle.badge.xmark", title: String(localized: "No account"), alignment: .trailing, y: 0.76)
            ]
        ),
        Page(
            content: .feature(icon: "wifi", screenshot: "AppConnect"),
            title: String(localized: "Pair once. Stay connected."),
            body: """
                Choose your Mac, compare the six-digit code, and Peering remembers it. Next time, \
                reconnect nearby or from another network without pairing again.
                """,
            chips: [
                FloatingChip(symbol: "lock.shield", title: String(localized: "Six-digit code"), alignment: .leading, y: 0.18),
                FloatingChip(symbol: "arrow.triangle.2.circlepath", title: String(localized: "Reconnects itself"), alignment: .trailing, y: 0.62)
            ]
        ),
        Page(
            content: .feature(icon: "macwindow", screenshot: "AppSources"),
            title: String(localized: "See exactly what you need"),
            body: """
                Bring over a whole display, one app, a single window, or any of your Spaces. Jump \
                between them whenever you like without ending the session.
                """,
            chips: [
                FloatingChip(symbol: "display", title: String(localized: "Whole display"), alignment: .leading, y: 0.14),
                FloatingChip(symbol: "macwindow", title: String(localized: "Single window"), alignment: .trailing, y: 0.46),
                FloatingChip(symbol: "square.stack.3d.up", title: String(localized: "Any Space"), alignment: .leading, y: 0.76)
            ]
        ),
        Page(
            content: .feature(icon: "hand.point.up.left", screenshot: "AppControls"),
            title: String(localized: "Your Mac, under your fingers"),
            body: """
                Tap, type, scroll, zoom, use shortcuts, or steer the pointer with the joystick. \
                Switch to Observe whenever you only want to look.
                """,
            chips: [
                FloatingChip(symbol: "cursorarrow.motionlines", title: String(localized: "Joystick pointer"), alignment: .leading, y: 0.2),
                FloatingChip(symbol: "command", title: String(localized: "Shortcuts"), alignment: .trailing, y: 0.5),
                FloatingChip(symbol: "eye", title: String(localized: "Observe mode"), alignment: .leading, y: 0.78)
            ]
        ),
        Page(
            content: .feature(icon: "arrow.triangle.2.circlepath", screenshot: "AppPictureInPicture"),
            title: String(localized: "Your session follows you"),
            body: """
                Leave the app or lock your phone without losing the connection. Picture in Picture \
                keeps your Mac in view, while Live Activities keep the session close at hand.
                """,
            chips: [
                FloatingChip(symbol: "pip", title: String(localized: "Picture in Picture"), alignment: .leading, y: 0.2),
                FloatingChip(symbol: "lock.iphone", title: String(localized: "Live Activity"), alignment: .trailing, y: 0.62)
            ]
        ),
        Page(
            content: .feature(icon: "square.grid.2x2", screenshot: "AppMosaic"),
            title: String(localized: "See everything at once"),
            body: """
                Lay out windows, apps and displays side by side and watch them all live. Tap any \
                tile to take control, and come back to the arrangement when you are done.
                """,
            chips: [
                FloatingChip(symbol: "square.grid.2x2", title: String(localized: "Live tiles"), alignment: .trailing, y: 0.18),
                FloatingChip(symbol: "hand.tap", title: String(localized: "Tap to take control"), alignment: .leading, y: 0.66)
            ]
        ),
        Page(
            content: .notification,
            title: String(localized: "Told when a shell is waiting"),
            body: """
                A build that finishes, a prompt for a password, a command that wants an answer: \
                the Mac tells you, on the Lock Screen and with the app closed.
                """,
            chips: [
                FloatingChip(symbol: "lock.iphone", title: String(localized: "Lock Screen"), alignment: .leading, y: 0.12),
                FloatingChip(symbol: "bell.badge", title: String(localized: "App closed, still told"), alignment: .trailing, y: 0.5)
            ]
        ),
        Page(
            content: .plans,
            title: String(localized: "Start free. Go farther when you need."),
            body: """
                Use Peering on your own network for free, for as long as you like. Upgrade when \
                you want more relay time or the tools built for working away from your Mac.
                """
        )
    ]

    struct Page {
        let content: Content
        let title: String
        let body: String

        var device: Device = .phone

        var chips: [FloatingChip] = []

        enum Device {
            case phone
            case mac(companion: String)
        }

        enum Content {
            case feature(icon: String, screenshot: String? = nil, tabletScreenshot: String? = nil)
            case notification
            case plans

            var wordsAreHeld: Bool {
                switch self {
                case .feature, .notification: return true
                case .plans: return false
                }
            }
        }
    }
}
