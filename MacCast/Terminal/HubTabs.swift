import SwiftUI

enum HubTab: String {
    case agents
    case terminals
    case files
}

/// Tabs over the hub: the agents (chats, launchers, their history), plain shells, and the Mac's folders.
struct HubTabs: View {
    @Binding var selection: HubTab
    let terminalCount: Int
    let agentCount: Int
    let agentsBusy: Bool
    let offersFiles: Bool
    /// For the navigation bar: shorter, titles only, and no margins of its own.
    var compact = false

    @Namespace private var pill

    var body: some View {
        HStack(spacing: 4) {
            tab(.agents, title: "Agents", symbol: "sparkles", count: agentCount, busy: agentsBusy)
            tab(.terminals, title: "Terminals", symbol: "terminal", count: terminalCount, busy: false)
            if offersFiles { tab(.files, title: "Files", symbol: "folder", count: 0, busy: false) }
        }
        .padding(compact ? 3 : 4)
        .background(.white.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
        .padding(.horizontal, compact ? 0 : 16)
        .padding(.top, compact ? 0 : 8)
        .padding(.bottom, compact ? 0 : 4)
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func tab(_ tab: HubTab, title: LocalizedStringKey, symbol: String, count: Int, busy: Bool) -> some View {
        let selected = selection == tab
        return Button {
            withAnimation(.snappy(duration: 0.28)) { selection = tab }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .symbolEffect(.pulse, isActive: busy)
                Text(title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(selected ? ColorPalette.ink : .white.opacity(0.8))
                        .padding(.horizontal, 6)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(selected ? ColorPalette.onInk.opacity(0.75) : .white.opacity(0.14), in: Capsule())
                        .contentTransition(.numericText())
                }
            }
            .foregroundStyle(selected ? ColorPalette.onInk : .white.opacity(0.75))
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background {
                if selected {
                    Capsule()
                        .fill(ColorPalette.ink)
                        .matchedGeometryEffect(id: "selection", in: pill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
