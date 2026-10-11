import Foundation

/// The improvements the sheet announces. Change `id` and the items together when there is something new to say: users who have seen the old id are shown the sheet once more.
struct WhatsNewRelease {
    struct Item: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { symbol }
    }

    let id: String
    let items: [Item]

    static let current: WhatsNewRelease? = WhatsNewRelease(
        id: "2026-10-agents",
        items: [
            Item(
                symbol: "clock.arrow.circlepath",
                title: String(localized: "Your Mac's Claude chats"),
                detail: String(localized: "Chats you ran in Terminal on the Mac now show under History, ready to pick up from your phone.")
            ),
            Item(
                symbol: "checkmark.circle",
                title: String(localized: "Next steps after a turn"),
                detail: String(localized: "When Claude finishes editing, tap to review the changes, run the tests or get a summary.")
            ),
            Item(
                symbol: "lock.iphone",
                title: String(localized: "Chats on the Lock Screen"),
                detail: String(localized: "The Live Activity keeps your open chat in view, including once it has finished.")
            ),
            Item(
                symbol: "arrow.triangle.2.circlepath",
                title: String(localized: "Steadier reconnects"),
                detail: String(localized: "Restart the Mac app and your phone keeps trying, instead of giving up after a few seconds.")
            ),
        ]
    )
}
