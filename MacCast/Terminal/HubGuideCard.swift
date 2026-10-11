import SwiftUI

/// What a hub page is for, in a few lines, until the person has read it once. The page heading's help button brings it back.
struct HubGuideCard: View {
    struct Item: Identifiable {
        let symbol: String
        let title: LocalizedStringKey
        let detail: LocalizedStringKey
        var id: String { symbol }
    }

    let title: LocalizedStringKey
    let items: [Item]
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(DisplayFont.display(22))
                .tracking(-0.5)
                .foregroundStyle(ColorPalette.ink)
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 12) {
                    IconTile(symbol: item.symbol, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(ColorPalette.ink)
                        Text(item.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Button(action: dismiss) {
                Text("Got it")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ColorPalette.onInk)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(ColorPalette.ink, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .cardSurface()
        .padding(.top, 16)
    }
}

extension HubGuideCard {
    static func agents(dismiss: @escaping () -> Void) -> HubGuideCard {
        HubGuideCard(
            title: "How agents work",
            items: [
                Item(
                    symbol: "sparkles",
                    title: "Pick an agent below",
                    detail: "The bar at the bottom chooses which coding agent you talk to. Tap its name to switch."
                ),
                Item(
                    symbol: "bubble.left.and.text.bubble.right",
                    title: "A chat works in a folder",
                    detail: "Chat with an agent and it works on your Mac in the folder you pick. The chat stays here when you leave."
                ),
                Item(
                    symbol: "hand.raised",
                    title: "Waiting on you",
                    detail: "A chat marked this way needs a yes or a no before the agent carries on."
                ),
                Item(
                    symbol: "checklist",
                    title: "To review",
                    detail: "Files an agent changed gather in one place, so you can look before you keep them."
                ),
            ],
            dismiss: dismiss
        )
    }

    static func terminals(dismiss: @escaping () -> Void) -> HubGuideCard {
        HubGuideCard(
            title: "How terminals work",
            items: [
                Item(
                    symbol: "terminal",
                    title: "A real shell on your Mac",
                    detail: "Each card is a shell running on the Mac. It keeps running when you disconnect."
                ),
                Item(
                    symbol: "plus",
                    title: "Start one",
                    detail: "The New terminal button in the bar opens a shell in a folder you pick."
                ),
                Item(
                    symbol: "hand.tap",
                    title: "Tap to open, hold to manage",
                    detail: "Hold a card to rename it or end it."
                ),
                Item(
                    symbol: "bell.badge",
                    title: "When a shell needs you",
                    detail: "A card is marked when its shell stops to ask for a password or a confirmation."
                ),
            ],
            dismiss: dismiss
        )
    }

    static func chat(dismiss: @escaping () -> Void) -> HubGuideCard {
        HubGuideCard(
            title: "Before you start",
            items: [
                Item(
                    symbol: "hand.raised",
                    title: "How much it asks first",
                    detail: "The chip under the chat sets it. Manual asks before the agent edits or runs anything."
                ),
                Item(
                    symbol: "at",
                    title: "Type / or @",
                    detail: "A slash lists the agent's commands. An at sign points it at a file in the folder."
                ),
                Item(
                    symbol: "doc.badge.gearshape",
                    title: "See what it changed",
                    detail: "More, then Changes, shows the files the agent edited."
                ),
            ],
            dismiss: dismiss
        )
    }
}
