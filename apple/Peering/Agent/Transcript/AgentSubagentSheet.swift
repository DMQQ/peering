import PeeringKit
import RemoteCore
import SwiftUI

struct AgentSubagentSelection: Identifiable {
    let id: String
}

/// What the sub-agents a chat spawned did, one at a time, with a strip to move between them.
struct AgentSubagentSheet: View {
    let sessionID: UUID
    @State var selectedCallID: String
    @Environment(SessionModel.self) private var model
    @State private var expandedTools: Set<UUID> = []

    private var subagents: [(call: AgentToolCall, transcript: AgentTranscript)] {
        model.agentSessions.first { $0.id == sessionID }?.transcript.subagents ?? []
    }

    private var selected: AgentTranscript? {
        subagents.first { $0.call.id == selectedCallID }?.transcript
    }

    var body: some View {
        VStack(spacing: 0) {
            if subagents.count > 1 { strip }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let selected {
                        ForEach(selected.items) { item in
                            AgentTranscriptRow(
                                item: item,
                                expandedTools: $expandedTools,
                                canSend: false,
                                resend: { _ in }
                            )
                        }
                        if selected.state == .working { AgentThinkingRow() }
                    }
                }
                .padding(14)
                .animation(Motion.settle, value: selected?.items.count)
            }
            .defaultScrollAnchor(.bottom)
        }
        .background(ColorPalette.backdrop)
    }

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(subagents, id: \.call.id) { subagent in
                    let isSelected = subagent.call.id == selectedCallID
                    Button {
                        withAnimation(Motion.settle) { selectedCallID = subagent.call.id }
                    } label: {
                        HStack(spacing: 6) {
                            if subagent.transcript.state == .working {
                                ProgressView().controlSize(.mini).tint(.white.opacity(0.7))
                            }
                            Text(subagent.call.detail ?? String(localized: "Sub-agent"))
                                .lineLimit(1)
                        }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(isSelected ? ColorPalette.onInk : .white.opacity(0.7))
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(Capsule().fill(isSelected ? ColorPalette.ink : .clear))
                        .overlay(Capsule().strokeBorder(.white.opacity(isSelected ? 0 : 0.14)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}
