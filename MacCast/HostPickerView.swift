import MacCastKit
import RemoteCore
import SSHCore
import SwiftUI
import UIKit

/// The app's five places, in the order the bar shows them.
///
/// A whole file's business rather than the picker's alone, which is why it sits outside it: the bar
/// draws itself from this list, and a nested type would be private to the picker. It is still
/// `private`, so the list of the app's screens does not leave this file.
///
/// The bar reads its titles and glyphs from here rather than from a second list beside it, so the
/// two cannot come apart: a sixth screen means a sixth case, and the switch in
/// ``HostPickerView/content(for:)`` does not compile until that case has somewhere to go.
private enum Screen: CaseIterable, Identifiable {
    case connect, servers, sessions, faq, settings

    var id: Self { self }

    var title: String {
        switch self {
        case .connect: "Connect"
        case .servers: "Servers"
        case .sessions: "Sessions"
        case .faq: "FAQ"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .connect: "macbook.and.iphone"
        case .servers: "server.rack"
        case .sessions: "clock.fill"
        case .faq: "questionmark.circle.fill"
        case .settings: "gearshape.fill"
        }
    }
}

/// Root navigation for connection, sessions, help, and settings.
struct HostPickerView: View {
    @Binding var acknowledgedFailure: String?

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

    private var compactNavigation: some View {
        TabView(selection: $screen) {
            ForEach(Screen.allCases) { item in
                content(for: item)
                    // The bar goes while a shell is up, and it is asked for on the screen rather
                    // than on the tab view: applied there the bar is made invisible but is not
                    // taken away, and its five items stay in the accessibility tree over the
                    // shell. The condition belongs to the Servers tab, because the shell screen
                    // is that tab's own root and nothing about the hierarchy changes when it
                    // opens.
                    .toolbar(
                        item == .servers && servers.selectedTerminal != nil ? .hidden : .visible,
                        for: .tabBar
                    )
                    .tabItem { Label(item.title, systemImage: item.symbol) }
                    .tag(item)
            }
        }
        .tint(ColorPalette.accent)
        .preferredColorScheme(.dark)
        .onChange(of: servers.wantsFocus, initial: true, focusServers)
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
        // `initial: true`, because "open a shell on prod" usually launches the app rather than
        // arriving at one already open, so the flag is already up by the time this view first
        // appears and a plain `onChange` would sit there waiting for it to change.
        guard wantsFocus else { return }
        screen = .servers
        // Cleared, or the tab would jump back here every time the user tried to leave it.
        servers.wantsFocus = false
    }

    /// The screen behind each tab.
    ///
    /// One switch rather than five copies inlined into the tab view, so the five places the app
    /// has are stated once. The bar's own titles and glyphs come from ``Screen``, which the tab
    /// view reads directly.
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

/// Where the other half of the product comes from.
///
/// **The Mac app is not in the App Store.** It is a download, and that makes this the only address
/// that reaches it: the phone app cannot find a Mac that has nothing running on it, cannot pair
/// with one, and shows an empty list until that download is installed and opened. So the two rows
/// that carry this link are not marketing in a settings screen, they are the two places somebody
/// is stuck without it.
///
/// Named once here for the reason ``Legal`` is named once in `PaywallView`: the address has to
/// agree with the site, the App Store listing and the docs, and only one of those can be compiled.
enum PeeringSite {
    /// The download page rather than the home page: it is one tap further from a visitor who has
    /// not decided and one tap closer to the file for somebody who has.
    static let download = URL(string: "https://getpeering.app/download")!

    /// The two documents that have to be reachable without leaving the app for a search engine.
    ///
    /// The extensionless forms, which is the same shape as ``download`` and the form the App Store
    /// listing and the receipts point at. Both are served, and the one that is written here is the
    /// one that stays the same if the site ever stops being a folder of `.html` files.
    static let privacy = URL(string: "https://getpeering.app/privacy")!
    static let terms = URL(string: "https://getpeering.app/terms")!
}
