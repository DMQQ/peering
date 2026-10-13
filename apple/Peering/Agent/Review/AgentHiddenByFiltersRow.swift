import SwiftUI

/// The line that says how many files the filters took out, and opens them.
struct AgentHiddenByFiltersRow: View {
    let count: Int
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "eye.slash").font(.system(size: 12, weight: .semibold))
                Text("\(count) hidden by filters").font(.system(size: 13, weight: .medium))
                Spacer(minLength: 8)
                Text("Show").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 12)
            .frame(height: 40)
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12)) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}
