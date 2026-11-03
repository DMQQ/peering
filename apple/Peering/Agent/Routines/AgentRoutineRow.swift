import RemoteCore
import SwiftUI

/// One routine: what it is, when it runs, how its last run went, and a way to run it now.
struct AgentRoutineRow: View {
    @Environment(SessionModel.self) private var model
    let routine: AgentRoutine
    let edit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Button(action: edit) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: routine.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ColorPalette.ink)
                    Text(verbatim: summary)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                    Text(verbatim: AgentRoutineText.lastRun(routine.lastRun))
                        .font(.caption)
                        .foregroundStyle(statusTint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            runButton
        }
        .cardSurface()
    }

    private var summary: String {
        let agent = TerminalAgent.all.first { $0.id == routine.agentID }?.name ?? routine.agentID
        let parts = [agent, AgentRoutineText.schedule(routine.schedule), AgentRoutineText.nextRun(routine)].compactMap { $0 }
        return parts.joined(separator: " · ")
    }

    private var isRunning: Bool { routine.lastRun?.outcome == .running }

    private var runButton: some View {
        Button {
            model.runAgentRoutineNow(routine.id)
        } label: {
            (isRunning ? Text("Running") : Text("Run now"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(ColorPalette.ink)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .overlay(Capsule().strokeBorder(.white.opacity(0.2)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isRunning)
    }

    private var statusTint: Color {
        switch routine.lastRun?.outcome {
        case .failed, .skipped: ColorPalette.danger
        case .stopped: ColorPalette.caution
        default: .white.opacity(0.6)
        }
    }
}
