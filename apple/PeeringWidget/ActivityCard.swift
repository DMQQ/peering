import SwiftUI

/// The one card both Live Activities are drawn from; they differ only in what they put in it.
struct ActivityCard: View {
    let symbol: String
    let tone: ActivityTone
    let name: String
    /// The state in words, with any count folded in: "Connected · 3 shells".
    /// One string, not a status and a chip: on a narrow phone the tail truncates, costing the count rather than the state.
    let status: String
    /// Nil until there is something to time; the system advances the clock from it.
    var startedAt: Date?
    var action: ActivityCardAction?
    /// Set where the state is the point (an agent chat): the status line gets this glyph and the tone's colour, and the tile is tinted with it, so the states differ by more than a dot.
    var statusSymbol: String?

    var work: [SessionActivityAttributes.ContentState.Work] = []
    var plan: ActivityCardPlan?

    static let workRows = 3
    /// A card pushed by the Mac names nothing it is doing.
    static let fallbackName = String(localized: "Coding agent")

    static let tile: CGFloat = 42
    static let tileCorner = tile * 0.286
    static let tileGlyph = tile * 0.405

    /// The width the clock is pinned to: seven glyphs for `1:23:45`. A fixed box, not a maximum, because it decides where the text ends.
    static let timerWidth: CGFloat = 68

    /// What the card is filled with and the dot's ring is drawn in. Heavy: over a bright wallpaper `.secondary` text read as a grey ghost at 55%.
    static let backgroundTint = Color.black.opacity(0.7)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sessionRow
            if let plan {
                PlanBar(plan: plan)
            }
            if !work.isEmpty {
                Rectangle()
                    .fill(.white.opacity(0.18))
                    .frame(height: 1)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(work.prefix(Self.workRows)), id: \.self) { item in
                        workRow(item)
                    }
                    if work.count > Self.workRows {
                        Text("+\(work.count - Self.workRows) more")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
        }
        // The card claims the width: an activity is laid out at its ideal size and centred, and a `Spacer` only takes the room it is offered.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func workRow(_ item: SessionActivityAttributes.ContentState.Work) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 15, alignment: .leading)

            Text(item.name.isEmpty ? Self.fallbackName : item.name)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)

            if let detail = item.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            // The word only where it is the point: waiting on the user.
            if item.state != .live {
                Text(item.state == .waiting ? "Waiting" : "Failed")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tone(for: item.state))
            }

            Circle()
                .fill(tone(for: item.state))
                .frame(width: 7, height: 7)
        }
    }

    private func tone(for state: SessionActivityAttributes.ContentState.Work.State) -> Color {
        switch state {
        case .live: return ActivityTone.live.tint
        case .waiting: return ActivityTone.pending.tint
        case .failed: return ActivityTone.lost.tint
        }
    }

    private var sessionRow: some View {
        HStack(spacing: 12) {
            ActivityTile(symbol: symbol, tone: tone, isTinted: statusSymbol != nil)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(name)
                        .font(.headline)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    // Nothing in the pending case, and the row does not move: the End button sits on the line below.
                    if let startedAt {
                        Text(startedAt, style: .timer)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                            // A `.timer` ignores its frame's alignment and fills the width offered, so line alignment positions it and the frame stops it taking the row.
                            .multilineTextAlignment(.trailing)
                            .frame(width: ActivityCard.timerWidth, alignment: .trailing)
                    }
                }

                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        if let statusSymbol {
                            Image(systemName: statusSymbol)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(tone.tint)
                        }
                        Text(status)
                            .font(.subheadline)
                            .foregroundStyle(statusSymbol == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(tone.tint))
                            .lineLimit(1)
                    }

                    // Without this the End capsule sits right after the status word: an `HStack` leaves the rest of the line empty.
                    Spacer(minLength: 8)

                    if let action {
                        Link(destination: action.url) {
                            Text(action.title).activityAction()
                        }
                        .fixedSize()
                    }
                }
            }
        }
    }
}

/// A session's state, as the colour of the dot on its tile.
///
/// The colours are copies of `ColorPalette`'s (`Peering/Design/Theme.swift`), which this target cannot link.
enum ActivityTone {
    case live
    case pending
    case lost
    /// A turn that ended well: the app's one accent blue, so it reads apart from the green of work in progress.
    case finished

    var tint: Color {
        switch self {
        case .live: return .green
        case .pending: return Color(red: 0.97, green: 0.75, blue: 0.35)
        case .lost: return Color(red: 0.98, green: 0.45, blue: 0.40)
        case .finished: return Color(red: 0.40, green: 0.65, blue: 1.0)
        }
    }
}

/// One thing a card can do, which is always a link: a widget cannot run the app's code, so every
/// control on one of these is a URL the app answers.
struct ActivityCardAction {
    let title: String
    let url: URL
}

/// The subject of the card: a glyph in a rounded tile with the state in a dot on its corner.
private struct ActivityTile: View {
    let symbol: String
    let tone: ActivityTone
    let isTinted: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: symbol)
                .font(.system(size: ActivityCard.tileGlyph, weight: .medium))
                .foregroundStyle(isTinted ? tone.tint : .white)
                .frame(width: ActivityCard.tile, height: ActivityCard.tile)
                .background(
                    isTinted ? tone.tint.opacity(0.2) : .white.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: ActivityCard.tileCorner, style: .continuous)
                )

            Circle()
                .fill(tone.tint)
                .frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(ActivityCard.backgroundTint, lineWidth: 1.5))
                .offset(x: 2, y: 2)
        }
        // The kind is in the glyph, which VoiceOver reads as a symbol name, so the words carry the state.
        .accessibilityHidden(true)
    }
}

private extension View {
    func activityAction() -> some View {
        font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(.white.opacity(0.16), in: Capsule())
    }
}

/// An agent's own plan under the card: how far along it is and the step it is on.
struct ActivityCardPlan {
    let done: Int
    let total: Int
    let stepNumber: Int?
    let step: String?
}

struct PlanBar: View {
    let plan: ActivityCardPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            PlanSegments(done: plan.done, total: plan.total)
            HStack(spacing: 6) {
                if let number = plan.stepNumber {
                    Text("Step \(number) of \(plan.total)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                if let step = plan.step {
                    Text(step)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
        }
    }
}

/// Done steps bright, the one in hand half, the rest faint; a long plan is one bar.
struct PlanSegments: View {
    let done: Int
    let total: Int

    var body: some View {
        if total <= 14 {
            HStack(spacing: 3) {
                ForEach(0..<total, id: \.self) { index in
                    Capsule()
                        .fill(.white.opacity(index < done ? 0.85 : (index == done ? 0.4 : 0.14)))
                        .frame(height: 4)
                }
            }
        } else {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.14))
                    Capsule().fill(.white.opacity(0.85))
                        .frame(width: geometry.size.width * CGFloat(done) / CGFloat(max(total, 1)))
                }
            }
            .frame(height: 4)
        }
    }
}
