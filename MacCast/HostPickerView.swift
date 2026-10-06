import MacCastKit
import RemoteCore
import SSHCore
import SwiftUI
import UIKit

/// Drawn from this list so a sixth screen needs a sixth case, and the switch in ``HostPickerView/content(for:)`` fails to compile without one.
private enum Screen: CaseIterable, Identifiable {
    case connect, servers, sessions, faq, settings

    var id: Self { self }

    /// Localized here: `Label(item.title, ...)` takes a String as is and never looks it up.
    var title: String {
        switch self {
        case .connect: String(localized: "Connect")
        case .servers: String(localized: "Servers")
        case .sessions: String(localized: "Sessions")
        case .faq: String(localized: "FAQ")
        case .settings: String(localized: "Settings")
        }
    }

    /// One weight for all five: the composite glyphs (`.macbook.and.iphone`, `server.rack`) have no filled variant, so outline is the one style every symbol has.
    var symbol: String {
        switch self {
        case .connect: "macbook.and.iphone"
        case .servers: "server.rack"
        case .sessions: "clock"
        case .faq: "questionmark.circle"
        case .settings: "gearshape"
        }
    }
}

struct HostPickerView: View {
    @Binding var acknowledgedFailure: String?

    @Environment(SessionModel.self) private var model
    @Environment(SSHModel.self) private var servers
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var screen: Screen = .connect

    @ViewBuilder
    var body: some View {
        if horizontalSizeClass == .regular {
            wideNavigation
        } else {
            compactNavigation
        }
    }

    @ViewBuilder
    private var compactNavigation: some View {
        Group {
            if #available(iOS 26.1, *) {
                compactTabs
                    .tabViewBottomAccessory(isEnabled: showsSessionAccessory) {
                        sessionAccessory
                    }
            } else if #available(iOS 26, *) {
                if showsSessionAccessory {
                    compactTabs
                        .tabViewBottomAccessory {
                            sessionAccessory
                        }
                } else {
                    compactTabs
                }
            } else {
                // A bottom toolbar does not move with a minimizing tab bar. There is no native
                // accessory before iOS 26, so older systems deliberately show no substitute.
                compactTabs
            }
        }
        .tint(ColorPalette.accent)
        .preferredColorScheme(.dark)
        .onChange(of: servers.wantsFocus, initial: true, focusServers)
        .tabBarMinimizeOnScrollIfAvailable()
    }

    private var compactTabs: some View {
        TabView(selection: $screen) {
            ForEach(Screen.allCases) { item in
                content(for: item)
                    // The bar is hidden on the Servers tab's screen rather than on the tab view: applied there it is invisible but stays in the accessibility tree over the shell.
                    .toolbar(
                        item == .servers && servers.selectedTerminal != nil ? .hidden : .visible,
                        for: .tabBar
                    )
                    .tabItem { Label(item.title, systemImage: item.symbol) }
                    .tag(item)
            }
        }
    }

    private var showsSessionAccessory: Bool {
        let hasSessions = !model.openSessions.isEmpty || !servers.openShells.isEmpty
        let terminalIsUp = screen == .servers && servers.selectedTerminal != nil
        return hasSessions && !terminalIsUp
    }

    private var sessionAccessory: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(model.openSessions) { session in
                    Button {
                        model.activateSession(session.id)
                    } label: {
                        sessionChip(
                            dot: macDotFill(session),
                            name: macName(session),
                            symbol: "desktopcomputer"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Return to \(macName(session))")
                }
                ForEach(servers.openShells) { terminal in
                    Button {
                        servers.selectedTerminalID = terminal.id
                        screen = .servers
                    } label: {
                        sessionChip(
                            dot: sshDotFill(terminal),
                            name: terminal.title,
                            symbol: "terminal"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Return to \(terminal.title)")
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity)
    }

    private func sessionChip(dot: Color, name: String, symbol: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(dot)
                .frame(width: 27, height: 27)
                .background(dot.opacity(0.13), in: Circle())
            Text(name)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 150, alignment: .leading)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(.white.opacity(0.055), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.75))
    }

    private func macName(_ session: MacSession) -> String {
        session.hostID.flatMap { model.displayName(forHostID: $0) }
            ?? session.hostName
            ?? String(localized: "A Mac")
    }

    private func macDotFill(_ session: MacSession) -> Color {
        if session.isReconnecting { return ColorPalette.caution }
        return session.phase == .ready ? .green : Color.primary.opacity(0.25)
    }

    private func sshDotFill(_ terminal: SSHTerminal) -> Color {
        switch terminal.phase {
        case .connecting: return ColorPalette.caution
        case .live: return .green
        case .ended: return ColorPalette.danger
        }
    }

    private var wideNavigation: some View {
        NavigationSplitView {
            List(Screen.allCases, selection: sidebarSelection) { item in
                Label(item.title, systemImage: item.symbol)
                    .tag(item)
            }
            .navigationTitle("Peering")
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 290)
            .scrollContentBackground(.hidden)
            .background(ColorPalette.backdrop)
        } detail: {
            content(for: screen)
        }
        .navigationSplitViewStyle(.balanced)
        .tint(ColorPalette.accent)
        .preferredColorScheme(.dark)
        .onChange(of: servers.wantsFocus, initial: true, focusServers)
    }

    private var sidebarSelection: Binding<Screen?> {
        Binding(
            get: { screen },
            set: { if let selected = $0 { screen = selected } }
        )
    }

    private func focusServers(_: Bool, _ wantsFocus: Bool) {
        // `initial: true`: a launch for "open a shell on prod" has the flag up before this view appears, so a plain onChange would wait for a change that never comes.
        guard wantsFocus else { return }
        screen = .servers
        // Cleared, or the tab would jump back here whenever the user tried to leave.
        servers.wantsFocus = false
    }

    @ViewBuilder
    private func content(for item: Screen) -> some View {
        switch item {
        case .connect: HomeTab(acknowledgedFailure: $acknowledgedFailure)
        case .servers: SSHTab()
        case .sessions: ActivityTab()
        case .faq: NavigationStack { FAQView() }
        case .settings: SettingsTab()
        }
    }
}

// MARK: - The site

/// The Mac app is not in the App Store, so this download is the only address that reaches it, and the phone app is empty without it. Named once so it agrees with the site, listing and docs.
private extension View {
    @ViewBuilder
    func tabBarMinimizeOnScrollIfAvailable() -> some View {
        if #available(iOS 26, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}

enum PeeringSite {
    static let download = URL(string: "https://getpeering.app/download")!

    /// Extensionless, matching ``download`` and what the App Store listing and receipts point at.
    static let privacy = URL(string: "https://getpeering.app/privacy")!
    static let terms = URL(string: "https://getpeering.app/terms")!
}
