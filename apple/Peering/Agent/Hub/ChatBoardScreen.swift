import PeeringKit
import SwiftUI

/// Every chat on every connected Mac, the ones waiting on the person first.
struct ChatBoardScreen: View {
    @Environment(SessionModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let board = model.chatBoard
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Only Macs connected right now are listed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if board.isEmpty {
                        Text("No chats on your connected Macs")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }
                    ForEach(board.sections) { section in
                        sectionCard(section)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .adaptiveContentColumn()
            }
            .background(ColorPalette.backdrop)
            .navigationTitle(String(localized: "All chats"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Close")) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func sectionCard(_ section: ChatBoard.Section) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Controls.sectionLabel(section.group.title, systemImage: section.group.symbol)
                .foregroundStyle(section.group == .needsYou ? AnyShapeStyle(ColorPalette.caution) : AnyShapeStyle(.secondary))
            VStack(spacing: 0) {
                ForEach(Array(section.entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                    }
                    Button {
                        dismiss()
                        model.openBoardChat(entry)
                    } label: {
                        ChatBoardRow(entry: entry, showsMacName: model.openSessions.count > 1)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            }
        }
    }
}

extension ChatBoardGroup {
    var title: String {
        switch self {
        case .needsYou: String(localized: "Needs you")
        case .working: String(localized: "Working")
        case .done: String(localized: "Done")
        }
    }

    var symbol: String {
        switch self {
        case .needsYou: "hand.raised.fill"
        case .working: "ellipsis.bubble"
        case .done: "checkmark.bubble"
        }
    }
}
