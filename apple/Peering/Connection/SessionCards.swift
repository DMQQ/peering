import PeeringKit
import RemoteCore
import SwiftUI

/// Cards that have already made their entrance on this launch: switching tabs rebuilds them, and replaying the stagger each time reads as lag.
@MainActor
enum ArrivalMemory {
    static var seen = Set<String>()
}

enum SessionBadge: Equatable {
    case working
    case needsYou
    case finished
    case running
    case starting
    case ended
    case failed
    case paused
}

/// One live chat or terminal on the Mac terminals page.
struct SessionCard<Subtitle: View>: View {
    let symbol: String
    let title: String
    let badge: SessionBadge
    let index: Int
    var folder: String?
    var preview: String?
    /// What it is doing this second, while a turn runs.
    var activity: String?
    var plan: AgentPlanProgress?
    /// When it began, and whether it is still running: a live one also shows how long it has been.
    var startedAt: Date?
    var isRunning = false
    @ViewBuilder var subtitle: () -> Subtitle

    @State private var arrived: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        symbol: String,
        title: String,
        badge: SessionBadge,
        index: Int,
        folder: String? = nil,
        preview: String? = nil,
        activity: String? = nil,
        plan: AgentPlanProgress? = nil,
        startedAt: Date? = nil,
        isRunning: Bool = false,
        @ViewBuilder subtitle: @escaping () -> Subtitle
    ) {
        self.symbol = symbol
        self.title = title
        self.badge = badge
        self.index = index
        self.folder = folder
        self.preview = preview
        self.activity = activity
        self.plan = plan
        self.startedAt = startedAt
        self.isRunning = isRunning
        self.subtitle = subtitle
        _arrived = State(initialValue: ArrivalMemory.seen.contains(Self.key(symbol, title)))
    }

    private func startedLine(_ date: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            HStack(spacing: 6) {
                Image(systemName: "clock").font(.system(size: 10, weight: .medium))
                Text("Started \(date.formatted(Calendar.current.isDateInToday(date) ? .dateTime.hour().minute() : .dateTime.month().day().hour().minute()))")
                if isRunning {
                    Text(verbatim: "·")
                    Text(verbatim: TerminalWindowCard.age(of: date)).monospacedDigit()
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.white.opacity(0.5))
            .lineLimit(1)
        }
    }

    private static func key(_ symbol: String, _ title: String) -> String { "session|\(symbol)|\(title)" }

    var body: some View {
        VStack(alignment: .leading, spacing: showsLive || preview != nil ? 10 : 0) {
            HStack(spacing: 12) {
                tile
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: title)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(ColorPalette.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 7) {
                        pill
                            .fixedSize()
                        HStack(spacing: 6) {
                            if let folder {
                                Image(systemName: "folder")
                                    .font(.system(size: 10, weight: .medium))
                                Text(verbatim: folder)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            subtitle()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            if showsLive {
                liveBlock
                    .transition(.blurReplace)
            } else if let preview, !preview.isEmpty {
                Text(verbatim: preview)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .transition(.opacity)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom)
                )
        }
        .runningEdge(badge == .working, radius: 20)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .opacity(arrived ? 1 : 0)
        .offset(y: arrived || reduceMotion ? 0 : 20)
        .scaleEffect(arrived || reduceMotion ? 1 : 0.96)
        .animation(
            reduceMotion ? .none : .spring(response: 0.5, dampingFraction: 0.72).delay(0.03 + Double(min(index, 6)) * 0.06),
            value: arrived
        )
        .animation(Motion.settle, value: badge)
        .animation(Motion.settle, value: preview)
        .onAppear {
            ArrivalMemory.seen.insert(Self.key(symbol, title))
            arrived = true
        }
    }

    private var showsLive: Bool {
        activity != nil || (plan.map { !$0.isFinished } ?? false)
    }

    private var liveBlock: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let activity {
                HStack(spacing: 8) {
                    Image(systemName: badge == .needsYou ? "hand.raised.fill" : "sparkle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(badge == .needsYou ? ColorPalette.caution : .white.opacity(0.85))
                        .symbolEffect(.pulse, isActive: badge == .working)
                    ShimmerText(text: activity, active: badge == .working)
                        .id(activity)
                        .transition(.blurReplace(.downUp))
                }
                .animation(Motion.settle, value: activity)
            }
            if let plan, !plan.isFinished {
                PlanTrack(plan: plan, isRunning: badge == .working)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var tile: some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(ColorPalette.ink)
            .symbolEffect(.pulse, isActive: badge == .working)
            .frame(width: 42, height: 42)
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var pill: some View {
        let (text, tint): (LocalizedStringKey, Color) = {
            switch badge {
            case .working: ("Working", .white.opacity(0.85))
            case .needsYou: ("Waiting on you", ColorPalette.caution)
            case .finished: ("Finished", .white.opacity(0.5))
            case .running: ("Running", .white.opacity(0.85))
            case .starting: ("Starting", .white.opacity(0.5))
            case .ended: ("Ended", .white.opacity(0.4))
            case .paused: ("Paused", .white.opacity(0.4))
            case .failed: ("Failed", ColorPalette.danger)
            }
        }()
        HStack(spacing: 5) {
            switch badge {
            case .working, .running:
                Circle().fill(badge == .running ? Color.green : tint).frame(width: 6, height: 6)
                    .modifier(PulseDot(active: badge == .working))
            case .needsYou:
                Image(systemName: "hand.raised.fill").font(.system(size: 9, weight: .bold)).symbolEffect(.pulse)
            case .failed:
                Image(systemName: "exclamationmark").font(.system(size: 9, weight: .bold))
            default:
                EmptyView()
            }
            Text(text).font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .overlay(Capsule().strokeBorder(tint.opacity(0.35)))
        .contentTransition(.opacity)
    }
}

