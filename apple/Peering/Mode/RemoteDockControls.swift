import RemoteCore
import SwiftUI

/// What the trackpad's dock asks for. The dock draws; the dock view acts.
struct RemoteDockControlActions {
    var onKeyboard: () -> Void
    var onDesktops: () -> Void
    var onApps: () -> Void
    var onShortcuts: () -> Void
    var onKey: (RemoteDockKey) -> Void
}

/// The trackpad's dock, built as the screen view's is: a glass card of rail buttons that pages when shut and opens into three rows from a chevron, with its page dots underneath.
struct RemoteDockControls: View {
    let typing: Bool
    /// The Mac's desktop count and the current one (1-based), when it sent them.
    let desktops: (count: Int, current: Int?)?
    let actions: RemoteDockControlActions
    let openPanel: RemoteDockPanel?
    /// The open panel's contents, drawn as the upper half of the dock's own glass.
    let panel: AnyView?
    let onClosePanel: () -> Void

    @State private var expanded = false
    @State private var page: Int? = 0

    /// What the shut dock takes: the card, the gap and the dots.
    static let restingHeight = ChromeMetrics.dockCollapsedHeight + ChromeMetrics.dockDotsGap + ChromeMetrics.dockPageDotsHeight

    private static let keys: [RemoteDockKey] = [.escape, .tab, .left, .up, .down, .right, .delete]

    private struct Item: Identifiable {
        let id: String
        let icon: String
        let label: String
        var panel: RemoteDockPanel?
        let action: () -> Void
    }

    var body: some View {
        let topRadius = panel == nil ? cornerRadius : ChromeMetrics.cornerRadius
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: topRadius,
            bottomLeadingRadius: cornerRadius,
            bottomTrailingRadius: cornerRadius,
            topTrailingRadius: topRadius,
            style: .continuous
        )
        return VStack(spacing: ChromeMetrics.dockDotsGap) {
            VStack(spacing: 0) {
                if let panel {
                    panelHandle
                    panel
                        .containerRelativeFrame(.vertical) { height, _ in height * 0.45 }
                        .id(openPanel)
                        .transition(.blurReplace(.downUp))
                    Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
                }
                card
            }
            .clipShape(shape)
            .background { Color.clear.glassSurface(in: shape) }
            pageDots
        }
        .containerRelativeFrame(.horizontal) { width, _ in width * ChromeMetrics.dockWidthFraction }
        .onChange(of: typing) { _, _ in page = 0 }
    }

    private var panelHandle: some View {
        Capsule()
            .fill(Color.white.opacity(0.32))
            .frame(width: 38, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 20)
            .contentShape(Rectangle())
            .onTapGesture(perform: onClosePanel)
            .gesture(DragGesture(minimumDistance: 4).onEnded { drag in
                if drag.translation.height > 40 { onClosePanel() }
            })
            .accessibilityElement()
            .accessibilityLabel(String(localized: "Close panel"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, onClosePanel)
    }

    private var cornerRadius: CGFloat {
        expanded ? ChromeMetrics.dockExpandedRadius : ChromeMetrics.dockCollapsedRadius
    }

    private var card: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(sheets.enumerated()), id: \.offset) { index, sheet in
                        rows(of: sheet)
                            .containerRelativeFrame(.horizontal)
                            .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $page)

            toggle.frame(width: ChromeMetrics.dockToggleWidth)
        }
        .frame(height: expanded ? ChromeMetrics.dockExpandedGridHeight : ChromeMetrics.buttonHeight)
        .padding(.vertical, ChromeMetrics.railPadding)
        .padding(.horizontal, ChromeMetrics.railSidePadding)
        .frame(height: expanded ? ChromeMetrics.dockExpandedHeight : ChromeMetrics.dockCollapsedHeight)
    }

    private func rows(of sheet: [Item]) -> some View {
        let columns = ChromeMetrics.dockColumns
        return VStack(spacing: ChromeMetrics.buttonGap) {
            ForEach(0..<(expanded ? ChromeMetrics.dockExpandedRows : 1), id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<columns, id: \.self) { column in
                        if let item = sheet[safe: row * columns + column] {
                            RailButton(icon: item.icon, label: item.label, selected: item.panel != nil && item.panel == openPanel, action: item.action)
                        } else {
                            Color.clear
                                .frame(maxWidth: .infinity)
                                .frame(height: ChromeMetrics.buttonHeight)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
        }
    }

    private var toggle: some View {
        Button {
            withAnimation(Motion.morph) { expanded.toggle() }
            page = 0
        } label: {
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: ChromeMetrics.buttonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(RailButtonStyle(scale: 0.94, haptic: true))
        .accessibilityLabel(expanded ? String(localized: "Hide the other controls") : String(localized: "Show the other controls"))
    }

    private var pageDots: some View {
        HStack(spacing: 0) {
            ForEach(0..<sheets.count, id: \.self) { index in
                Button {
                    withAnimation(Motion.settle) { page = index }
                } label: {
                    Circle()
                        .fill(index == (page ?? 0) ? Color.primary : Color.secondary.opacity(0.6))
                        .frame(width: 5, height: 5)
                        .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
                        .frame(width: 16, height: ChromeMetrics.dockPageDotsHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Page \(index + 1) of \(sheets.count)"))
            }
        }
        .frame(height: ChromeMetrics.dockPageDotsHeight)
    }

    private var sheets: [[Item]] {
        let capacity = ChromeMetrics.dockColumns * (expanded ? ChromeMetrics.dockExpandedRows : 1)
        return stride(from: 0, to: items.count, by: capacity).map {
            Array(items[$0 ..< min($0 + capacity, items.count)])
        }
    }

    /// The keys lead while the keyboard is up, since that is when they are wanted.
    private var items: [Item] {
        let controls = [
            Item(id: "keyboard", icon: "keyboard", label: String(localized: "Keyboard"), action: actions.onKeyboard),
            Item(id: "desktops", icon: "square.split.2x1", label: desktopTitle, panel: .desktops, action: actions.onDesktops),
            Item(id: "apps", icon: "rectangle.on.rectangle", label: String(localized: "Apps"), panel: .apps, action: actions.onApps),
            Item(id: "shortcuts", icon: "command", label: String(localized: "Shortcuts"), panel: .shortcuts, action: actions.onShortcuts),
        ]
        let keys = Self.keys.map { key in
            Item(id: "key-\(key.keyCode)", icon: key.symbol, label: key.shortName) { actions.onKey(key) }
        }
        return typing ? keys + controls : controls + keys
    }

    private var desktopTitle: String {
        guard let current = desktops?.current else { return String(localized: "Desktops") }
        return String(localized: "Desktop \(current)")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
