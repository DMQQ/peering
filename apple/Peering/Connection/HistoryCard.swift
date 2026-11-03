import PeeringKit
import RemoteCore
import SwiftUI

/// Past launches, as one card grouped by day.
struct HistoryCard: View {
    struct Entry: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let detail: String
        let date: Date
        let isLive: Bool
        let isEnabled: Bool
        /// Asked on the row itself, so the dialog opens from the thing it is about.
        var confirmation: Confirmation?
        /// The conversation shown on a long press, for entries whose transcript is on the phone.
        var peek: (() -> AnyView)?
        let run: () -> Void

        func matches(_ query: String) -> Bool {
            let query = query.trimmingCharacters(in: .whitespaces)
            return query.isEmpty || title.localizedCaseInsensitiveContains(query) || detail.localizedCaseInsensitiveContains(query)
        }
    }

    struct Confirmation {
        let title: LocalizedStringKey
        let message: LocalizedStringKey
        let proceed: LocalizedStringKey
    }

    let entries: [Entry]

    private var groups: [(title: String, items: [Entry])] {
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [Entry]] = [:]
        for entry in entries {
            let key: String
            if calendar.isDateInToday(entry.date) { key = String(localized: "Today") }
            else if calendar.isDateInYesterday(entry.date) { key = String(localized: "Yesterday") }
            else { key = entry.date.formatted(.dateTime.month(.abbreviated).day()) }
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(entry)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.element.title) { groupIndex, group in
                Text(verbatim: group.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 14)
                    .padding(.top, groupIndex == 0 ? 12 : 16)
                    .padding(.bottom, 4)
                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        Rectangle().fill(.white.opacity(0.06)).frame(height: 1).padding(.leading, 56)
                    }
                    HistoryRow(entry: entry)
                }
            }
            Color.clear.frame(height: 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom)
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct HistoryRow: View {
    let entry: HistoryCard.Entry
    @State private var isConfirming = false

    private func tap() {
        if entry.confirmation != nil { isConfirming = true } else { entry.run() }
    }

    @ViewBuilder
    var body: some View {
        if let peek = entry.peek {
            row
                .contextMenu {
                    Button("Open", systemImage: "arrow.up.right.square", action: tap)
                        .menuInk()
                } preview: {
                    peek()
                }
        } else {
            row
        }
    }

    private var row: some View {
        Button(action: tap) {
            HStack(spacing: 11) {
                Image(systemName: entry.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 32, height: 32)
                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: entry.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(ColorPalette.ink)
                        .lineLimit(1)
                    Text(verbatim: entry.detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if entry.isLive {
                    Text("Open")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ColorPalette.onInk)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(Capsule().fill(ColorPalette.ink))
                } else {
                    HStack(spacing: 5) {
                        Text(entry.date.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!entry.isEnabled)
        .confirmationDialog(
            entry.confirmation?.title ?? "",
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            if let confirmation = entry.confirmation {
                Button(confirmation.proceed, action: entry.run)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let confirmation = entry.confirmation { Text(confirmation.message) }
        }
    }
}
