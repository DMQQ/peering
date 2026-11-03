import SwiftUI

/// Outlined rows standing where the chats and History will be, so the page keeps one shape while the Mac answers.
struct AgentsPagePlaceholder: View {
    var body: some View {
        VStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.07))
                    .frame(height: 76)
            }
        }
        .padding(.top, 20)
        .accessibilityHidden(true)
    }
}
