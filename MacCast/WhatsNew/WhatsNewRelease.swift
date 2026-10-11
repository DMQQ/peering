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
        id: "2026-10-11",
        items: [
            Item(
                symbol: "clock.arrow.circlepath",
                title: String(localized: "Pick up any Claude chat"),
                detail: String(localized: "Chats from Terminal on your Mac show under History with their full conversation. Paused chats wait there too.")
            ),
            Item(
                symbol: "checkmark.shield",
                title: String(localized: "Answer from your phone"),
                detail: String(localized: "Allow or deny Claude Code prompts from any terminal or editor, and reply to a finished turn right from its notification.")
            ),
            Item(
                symbol: "gift",
                title: String(localized: "Everything is free"),
                detail: String(localized: "Every feature is open to everyone. Only relay time is limited, and invite codes earn you more.")
            ),
            Item(
                symbol: "arrow.triangle.2.circlepath",
                title: String(localized: "Steadier connection"),
                detail: String(localized: "Backgrounding no longer burns relay time, and a warning appears when your connection is too poor to work over.")
            ),
        ]
    )
}
