import PeeringKit
import SwiftUI

/// The way onto the board: how many chats are in each state, and a tap opens the whole list.
struct ChatBoardSummary: View {
    @Environment(SessionModel.self) private var model
    @State private var showsBoard = false

    var body: some View {
        let board = model.chatBoard
        if !board.isEmpty {
            Button { showsBoard = true } label: {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("All chats")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(ColorPalette.ink)
                        HStack(spacing: 14) {
                            ForEach(ChatBoardGroup.allCases, id: \.self) { group in
                                count(board.count(of: group), group: group)
                            }
                        }
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
            .sheet(isPresented: $showsBoard) {
                ChatBoardScreen()
                    .environment(model)
            }
        }
    }

    private func count(_ value: Int, group: ChatBoardGroup) -> some View {
        HStack(spacing: 4) {
            Text(value, format: .number)
                .font(.caption.weight(.semibold).monospacedDigit())
            Text(verbatim: group.title)
                .font(.caption)
        }
        .foregroundStyle(group == .needsYou && value > 0 ? AnyShapeStyle(ColorPalette.caution) : AnyShapeStyle(.white.opacity(0.6)))
        .accessibilityElement(children: .combine)
    }
}
