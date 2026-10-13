import SwiftUI

/// The peek of a History row with no screen or conversation behind it: what is known about it, so the long press still answers.
struct HistoryInfoPeek: View {
    let symbol: String
    let title: String
    let detail: String
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            Text(verbatim: title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(ColorPalette.ink)
                .lineLimit(2)
            Text(verbatim: detail)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(3)
                .truncationMode(.head)
            Text(date.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .frame(width: 320)
        .background(ColorPalette.backdrop)
        .preferredColorScheme(.dark)
    }
}
