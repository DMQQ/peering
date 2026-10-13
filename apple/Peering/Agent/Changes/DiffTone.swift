import PeeringKit
import SwiftUI

/// How a diff line is coloured: added and removed lines carry a tinted row and a saturated gutter marker, everything else stays white.
enum DiffTone {
    case added, removed, neutral

    /// Stronger under Increase Contrast or Reduce Transparency, where a faint tint can vanish.
    func tint(emphasised: Bool) -> Color {
        switch self {
        case .added: ColorPalette.added.opacity(emphasised ? 0.24 : 0.14)
        case .removed: ColorPalette.danger.opacity(emphasised ? 0.24 : 0.14)
        case .neutral: .clear
        }
    }

    var accent: Color? {
        switch self {
        case .added: ColorPalette.added
        case .removed: ColorPalette.danger
        case .neutral: nil
        }
    }
}

/// +N and -M in the diff colours, the pair every file row and header shows.
struct DiffCounts: View {
    let added: Int
    let removed: Int
    var font: Font = .system(size: 11, weight: .semibold, design: .monospaced)

    var body: some View {
        HStack(spacing: 6) {
            if added > 0 { Text(verbatim: "+" + AgentChangeStats.grouped(added)).foregroundStyle(ColorPalette.added) }
            if removed > 0 { Text(verbatim: "-" + AgentChangeStats.grouped(removed)).foregroundStyle(ColorPalette.danger) }
        }
        .font(font)
    }
}
