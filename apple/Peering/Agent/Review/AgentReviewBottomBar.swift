import SwiftUI

extension View {
    /// The soft blur the review list scrolls under at the bottom. The material's dark variant is pinned on it: left to the environment it rendered light grey. A soft top edge keeps the blur from ending in a line.
    func reviewBottomBackdrop() -> some View {
        background {
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                    .opacity(0.5)
                LinearGradient(colors: [.clear, ColorPalette.backdrop.opacity(0.9)], startPoint: .top, endPoint: .bottom)
            }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.4)], startPoint: .top, endPoint: .bottom))
            .ignoresSafeArea(edges: .bottom)
        }
    }
}

/// What replaces the search field while files are selected: the count, and the two things to do with them.
struct AgentReviewActionBar: View {
    let count: Int
    let clear: () -> Void
    let reject: () -> Void
    let markReviewed: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(rejectTitle: "Send back to fix")
            bar(rejectTitle: "Reject")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func bar(rejectTitle: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Button(action: clear) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: InputBar.height, height: InputBar.height)
                    .glassSurface(in: Circle(), interactive: true)
                    .contentShape(Circle())
            }
            .buttonStyle(RailButtonStyle(scale: 0.92))
            .accessibilityLabel(Text("Clear selection"))
            Text("\(count) selected")
                .font(.system(size: 14, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 0)
            Button(action: reject) {
                Label(rejectTitle, systemImage: "arrow.uturn.backward")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ColorPalette.danger)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 14)
                    .frame(height: InputBar.height)
                    .glassSurface(in: Capsule(), interactive: true)
                    .contentShape(Capsule())
            }
            .buttonStyle(RailButtonStyle(scale: 0.96))
            .accessibilityLabel(Text("Send back to fix"))
            .accessibilityIdentifier("review.reject")
            Button(action: markReviewed) {
                Label("Reviewed", systemImage: "checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ColorPalette.onInk)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 14)
                    .frame(height: InputBar.height)
                    .background(ColorPalette.ink, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(RailButtonStyle(scale: 0.96))
            .accessibilityIdentifier("review.markReviewed")
        }
    }
}
