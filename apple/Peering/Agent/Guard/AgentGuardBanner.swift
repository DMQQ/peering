import PeeringKit
import RemoteCore
import SwiftUI

/// Above the composer: a chat past its cap, with the waiting messages it holds, and the five-hour warning. Nothing when neither applies.
struct AgentGuardBanner: View {
    let session: RemoteAgentSession
    let waiting: Int

    @Environment(SessionModel.self) private var model
    @State private var dismissed = AgentGuardStore().dismissedWarnings

    private var overrun: AgentSpendingGuard.Overrun? {
        guard model.agentSpendingCapsAvailable else { return nil }
        return AgentSpendingGuard.overrun(cap: model.agentSpendingCap(for: session.id), usage: session.usage)
    }

    private var limitWarning: AgentLimitWarning? {
        guard let warning = AgentLimitWarning.current(in: session.usage?.limits ?? []), !dismissed.contains(warning.key) else { return nil }
        return warning
    }

    var body: some View {
        VStack(spacing: 6) {
            if let overrun { capRow(overrun) }
            if let limitWarning { limitRow(limitWarning) }
        }
        .padding(.horizontal, 14)
        .padding(.top, overrun == nil && limitWarning == nil ? 0 : 6)
        .animation(Motion.settle, value: overrun == nil)
        .animation(Motion.settle, value: limitWarning?.key)
    }

    private func capRow(_ overrun: AgentSpendingGuard.Overrun) -> some View {
        row(symbol: "gauge.with.dots.needle.100percent") {
            Text(AgentGuardText.overrun(overrun))
            Text(waiting > 0
                ? String(localized: "\(waiting) waiting message(s) are held until you send them on.")
                : String(localized: "Messages you queue now wait for you to send them on."))
                .foregroundStyle(.white.opacity(0.55))
        } trailing: {
            if waiting > 0 {
                Button(String(localized: "Send next")) { model.releaseHeldAgentPrompt(session.id) }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ColorPalette.ink)
                    .accessibilityIdentifier("chat.guard.sendNext")
            }
        }
        .accessibilityIdentifier("chat.guard.cap")
    }

    private func limitRow(_ warning: AgentLimitWarning) -> some View {
        row(symbol: "hourglass") {
            Text(AgentGuardText.limitTitle(warning))
            Text(AgentGuardText.limitBody(warning)).foregroundStyle(.white.opacity(0.55))
        } trailing: {
            Button {
                dismissed.insert(warning.key)
                AgentGuardStore().dismissedWarnings = dismissed
            } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(.white.opacity(0.55))
            .accessibilityLabel(Text("Dismiss"))
        }
        .accessibilityIdentifier("chat.guard.limit")
    }

    private func row(
        symbol: String,
        @ViewBuilder text: () -> some View,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ColorPalette.caution)
            VStack(alignment: .leading, spacing: 2) { text() }
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.16)))
        .transition(.blurReplace)
    }
}
