import RemoteCore
import SwiftUI

/// The way onto the routines list from the agents hub, for a Mac that keeps routines.
struct AgentRoutinesEntry: View {
    @Environment(SessionModel.self) private var model
    @State private var showsRoutines = false

    var body: some View {
        if model.hostSupportsAgentRoutines {
            Button { showsRoutines = true } label: {
                HStack(spacing: 11) {
                    Controls.icon("calendar.badge.clock")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Routines")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(ColorPalette.ink)
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(14)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
            .sheet(isPresented: $showsRoutines) {
                AgentRoutinesScreen()
                    .environment(model)
            }
        }
    }

    private var detail: String {
        let count = model.agentRoutines?.count ?? 0
        return count == 0
            ? String(localized: "Run an agent on a schedule while you are away")
            : String(localized: "\(count) on your Mac")
    }
}
