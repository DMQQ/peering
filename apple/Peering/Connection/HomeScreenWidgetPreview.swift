import MacCastKit
import MessageUI
import RemoteCore
import SSHCore
import SwiftUI
import UIKit

/// Side by side and to scale (a medium widget is a little over twice a small's width and the same height), derived from the width the card has.
struct HomeScreenWidgetPreview: View {
    let hostNames: [String]

    /// A medium widget is 338x158 points and a small is 158x158.
    private static let mediumToSmall: CGFloat = 2.14
    private static let gap: CGFloat = 12

    /// Seeded rather than measured on the first pass: `@State` starts at its declared value and the pair would otherwise be drawn once at the wrong size.
    @State private var smallSide: CGFloat = 94
    private static let design: CGFloat = 132

    private var primaryName: String { hostNames.first ?? String(localized: "Your Mac") }

    private var unit: CGFloat { smallSide / Self.design }

    var body: some View {
        HStack(alignment: .top, spacing: Self.gap) {
            column(String(localized: "Small")) { small }
            column(String(localized: "Medium")) { medium }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            guard width > 0 else { return }
            smallSide = (width - Self.gap) / (1 + Self.mediumToSmall)
        }
    }

    private func column<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var small: some View {
        VStack(spacing: 7 * unit) {
            Image(systemName: "display")
                .font(.system(size: 27 * unit, weight: .medium))
            Text(primaryName)
                .font(.system(size: 17 * unit, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text("Tap to connect")
                .font(.system(size: 11 * unit))
                .foregroundStyle(.secondary)
        }
        .frame(width: smallSide, height: smallSide)
        .widgetPreviewSurface(radius: 24 * unit)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 8 * unit) {
            HStack(spacing: 5 * unit) {
                Image(systemName: "display")
                    .font(.system(size: 10 * unit, weight: .medium))
                Text("PEERING")
                    .font(.system(size: 10 * unit, weight: .semibold, design: .rounded))
                    .tracking(1 * unit)
                Spacer()
            }
            .foregroundStyle(.secondary)

            ForEach(Array(displayedNames.enumerated()), id: \.offset) { _, name in
                HStack(spacing: 8 * unit) {
                    Image(systemName: "macbook")
                        .font(.system(size: 13 * unit, weight: .medium))
                    Text(name)
                        .font(.system(size: 13 * unit, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10 * unit, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(15 * unit)
        .frame(
            width: smallSide * Self.mediumToSmall,
            height: smallSide,
            alignment: .topLeading
        )
        .widgetPreviewSurface(radius: 24 * unit)
    }

    private var displayedNames: [String] {
        hostNames.isEmpty ? [String(localized: "Pair a Mac to connect")] : hostNames
    }
}
