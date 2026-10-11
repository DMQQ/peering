import ActivityKit
import SwiftUI
import WidgetKit

/// The agent chat that matters most, on the Lock Screen and in the Dynamic Island: the one waiting on you, else the busiest, else the latest to finish.
///
/// Same card as the sessions'; see ``ActivityCard``. The plan sits under it when the agent made one.
struct AgentChatLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentChatActivityAttributes.self) { context in
            let chat = context.state.chat
            ActivityCard(
                symbol: chat.symbol,
                tone: chat.state == .needsYou ? .pending : .live,
                name: chat.title,
                status: status(context.state),
                action: ActivityCardAction(title: chat.state == .needsYou ? String(localized: "Review") : String(localized: "Open"), url: chat.url),
                plan: plan(chat)
            )
            .activityBackgroundTint(ActivityCard.backgroundTint)
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let chat = context.state.chat
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(chat.title, systemImage: glyph(chat))
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let number = chat.planStepNumber, chat.planTotal > 0 {
                        Text("\(number)/\(chat.planTotal)")
                            .font(.title3.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(status(context.state))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if chat.hasUnfinishedPlan {
                            PlanSegments(done: chat.planDone, total: chat.planTotal)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: glyph(chat))
            } compactTrailing: {
                if chat.state == .needsYou {
                    Text("\(context.state.waiting)")
                        .font(.caption.monospacedDigit())
                } else if let number = chat.planStepNumber, chat.planTotal > 0 {
                    Text("\(number)/\(chat.planTotal)")
                        .font(.caption.monospacedDigit())
                } else {
                    Image(systemName: chat.state == .working ? "ellipsis" : chat.state == .failed ? "exclamationmark" : "checkmark")
                }
            } minimal: {
                Image(systemName: glyph(chat))
            }
            .keylineTint(.white)
            .widgetURL(chat.url)
        }
    }

    private func glyph(_ chat: AgentChatSnapshot) -> String {
        chat.state == .needsYou ? "hand.raised.fill" : chat.symbol
    }

    private func status(_ state: AgentChatActivityAttributes.ContentState) -> String {
        let chat = state.chat
        let base: String
        switch chat.state {
        case .needsYou: base = String(localized: "Waiting on you")
        case .working: base = chat.activity ?? String(localized: "Working")
        case .finished: base = String(localized: "Finished")
        case .failed: base = String(localized: "Stopped with an error")
        }
        let others = state.waiting + state.working - 1
        return others > 0 ? String(localized: "\(base) · +\(others) more") : base
    }

    private func plan(_ chat: AgentChatSnapshot) -> ActivityCardPlan? {
        guard chat.hasUnfinishedPlan else { return nil }
        return ActivityCardPlan(done: chat.planDone, total: chat.planTotal, stepNumber: chat.planStepNumber, step: chat.planStep)
    }
}
