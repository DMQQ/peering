import PeeringKit
import RemoteCore
import SwiftUI

/// What a chat has used and what is left, for this agent and for the others that are open.
///
/// Drawn only from what each CLI reports: a field it does not report is absent, never zero.
struct AgentUsageSheet: View {
    @Environment(SessionModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sessionID: UUID

    private var session: RemoteAgentSession? {
        model.agentSessions.first { $0.id == sessionID }
    }

    /// One session per other agent, the one that has said most recently, so an agent open twice is
    /// listed once.
    private var otherAgents: [RemoteAgentSession] {
        var seen: Set<String> = [session?.agentID ?? ""]
        return model.agentSessions.filter { seen.insert($0.agentID).inserted }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let session {
                        context(session)
                        tokens(session)
                        limits(session)
                    }
                    let others = otherAgents
                    if !others.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            sectionLabel("Other agents")
                            ForEach(others) { other in
                                otherAgent(other)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .background(ColorPalette.backdrop)
            .navigationTitle(session.map(agentName) ?? String(localized: "Usage"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(ColorPalette.backdrop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    // MARK: - Sections

    private func context(_ session: RemoteAgentSession) -> some View {
        let usage = session.usage
        return VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Context")
            card {
                if let used = usage?.contextUsedTokens {
                    if let window = usage?.contextWindowTokens, window > 0 {
                        let fraction = min(Double(used) / Double(window), 1)
                        HStack(alignment: .firstTextBaseline) {
                            Text(percent(fraction))
                                .font(.system(size: 28, weight: .semibold, design: .default))
                                .monospacedDigit()
                                .foregroundStyle(ColorPalette.ink)
                            Text("\(Self.tokens(used)) of \(Self.tokens(window)) tokens")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        meter(fraction, tint: fraction > 0.9 ? ColorPalette.caution : ColorPalette.ink)
                    } else {
                        Text("\(Self.tokens(used)) tokens")
                            .font(.system(size: 22, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(ColorPalette.ink)
                        note("The window size is not reported for this model.")
                    }
                } else {
                    note("Nothing yet. This appears after the first reply.")
                }
            }
        }
    }

    @ViewBuilder
    private func tokens(_ session: RemoteAgentSession) -> some View {
        if let usage = session.usage {
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("This chat")
                card {
                    row("Input", Self.tokens(usage.inputTokens))
                    row("Output", Self.tokens(usage.outputTokens))
                    if usage.cachedTokens > 0 {
                        row("Read from cache", Self.tokens(usage.cachedTokens))
                    }
                    if let cost = usage.costUSD {
                        row("Cost", cost.formatted(.currency(code: "USD").precision(.fractionLength(2...4))))
                    }
                }
            }
        }
    }

    private func limits(_ session: RemoteAgentSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Limit left")
            card {
                limitRows(session)
            }
        }
    }

    private func otherAgent(_ other: RemoteAgentSession) -> some View {
        card {
            Text(agentName(other))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ColorPalette.ink)
            limitRows(other)
        }
    }

    @ViewBuilder
    private func limitRows(_ session: RemoteAgentSession) -> some View {
        let limits = session.usage?.limits ?? []
        if limits.isEmpty {
            note("\(agentName(session)) does not report a limit.")
        } else {
            ForEach(limits, id: \.label) { limit in
                let left = 1 - limit.usedFraction
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(limit.label)
                            .font(.subheadline)
                            .foregroundStyle(ColorPalette.ink)
                        Spacer(minLength: 8)
                        Text("\(percent(left)) left")
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(ColorPalette.ink)
                    }
                    meter(left, tint: left < 0.05 ? ColorPalette.danger : (left < 0.2 ? ColorPalette.caution : ColorPalette.ink))
                    if let resets = limit.resetsAt {
                        Text("Renews \(resets.formatted(.relative(presentation: .named)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Pieces

    private func sectionLabel(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    /// Outlined and never filled: a translucent fill would collapse page, card and row into three
    /// greys a few points apart.
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(ColorPalette.ink)
        }
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func meter(_ fraction: Double, tint: Color) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1)
                Capsule()
                    .fill(tint)
                    .frame(width: max(proxy.size.width * min(max(fraction, 0), 1), 6))
            }
        }
        .frame(height: 8)
    }

    private func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    private func agentName(_ session: RemoteAgentSession) -> String {
        TerminalAgent.all.first { $0.id == session.agentID }?.name ?? session.title
    }

    /// 84,213 reads as "84.2K", and a window of 1,000,000 as "1M".
    static func tokens(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
}
