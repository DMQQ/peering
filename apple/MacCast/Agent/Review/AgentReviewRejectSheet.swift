import SwiftUI

/// Asks why the files are going back, so the agent gets the reason with the list rather than guessing at it.
struct AgentReviewRejectSheet: View {
    @Binding var reason: String
    let fileCount: Int
    let summary: String
    let send: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextField("Why are you rejecting?", text: $reason, axis: .vertical)
                    .lineLimit(4...10)
                    .focused($focused)
                    .padding(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.2)))
                    .accessibilityIdentifier("review.rejectReason")
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(ColorPalette.backdrop)
            .navigationTitle("Send back to fix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send back ^[\(fileCount) file](inflect: true)") {
                        send()
                        dismiss()
                    }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }
}
