import SwiftUI

struct ProgressOverlay: View {
    let title: String
    let detail: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text(title).font(.headline)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .glassSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

/// Session details, the capture-source picker, and the two destructive actions.
