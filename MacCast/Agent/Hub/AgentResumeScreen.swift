import MacCastKit
import RemoteCore
import SwiftUI

/// The conversations started in a terminal on the Mac, to pick one up from here.
struct AgentResumeScreen: View {
    @Environment(SessionModel.self) private var model

    @State private var confirming: AgentResumableSession?
    @State private var opening: String?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Claude Code conversations you started in a terminal on your Mac. Picking one continues it here with its history.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                content
            }
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .background(ColorPalette.backdrop)
        .navigationTitle("Continue from your Mac")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.refreshResumableSessions() }
        .confirmationDialog(
            "This conversation may be open on your Mac",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { session in
            Button("Continue here anyway") { open(session) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It was written to a moment ago. If a terminal still has it open, both would add to the same conversation.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let sessions = model.resumableSessions {
            if sessions.isEmpty {
                Text("No conversations found. Start Claude Code in a terminal on your Mac, and it appears here.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 16)
            } else {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                    if index > 0 { Controls.divider }
                    row(session)
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        }
    }

    private func row(_ session: AgentResumableSession) -> some View {
        Button {
            if session.mayBeOpenElsewhere { confirming = session } else { open(session) }
        } label: {
            HStack(spacing: 12) {
                IconTile(symbol: "arrow.uturn.forward", size: 38)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: session.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ColorPalette.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Image(systemName: "folder").font(.system(size: 10, weight: .medium))
                        Text(verbatim: (session.directory as NSString).lastPathComponent)
                            .font(.system(size: 11.5, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(verbatim: "·")
                        Text(session.modifiedAt.formatted(.relative(presentation: .named)))
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if session.mayBeOpenElsewhere {
                        Text("Active a moment ago")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                Spacer(minLength: 6)
                if opening == session.id {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(opening != nil)
        .accessibilityIdentifier("resume-row")
    }

    private func open(_ session: AgentResumableSession) {
        opening = session.id
        model.resumeAgentSession(session)
    }
}
