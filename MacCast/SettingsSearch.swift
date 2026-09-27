import SwiftUI

/// Filters the settings screens by what their sections are called and hold.
///
/// By section rather than by row: each card keeps its title and footer, so a match still says where
/// in the app the setting lives.
enum SettingsSearch {
    enum Section: CaseIterable {
        case device, controls, quality, remoteAccess, security, pip, widget, liveActivity
        case notifications, trustedMacs, identity, developer, more, legal
        // The in-session panel's own cards.
        case sessionInfo, activity, stream, sessionPicture, sessionPanels, privacy
        case sessionKeyboard, macros, pairedMacs, thisDevice

        /// The words a section answers to: its title, its rows, and what someone might type instead.
        var keywords: String {
            switch self {
            case .device: "this device name phone"
            case .controls: "session controls interaction observe control picture fit fill keyboard unicode keycode open keyboard text fields close panels after selecting"
            case .quality: "stream quality bitrate resolution video auto"
            case .remoteAccess: "remote access relay privacy mode internet away upgrade pro"
            case .security: "security face id touch id biometric unlock lock passcode"
            case .pip: "picture in picture pip float automatically floating window"
            case .widget: "home screen widget"
            case .liveActivity: "live activity lock screen dynamic island"
            case .notifications: "notifications terminal needs you alerts push reached"
            case .trustedMacs: "trusted macs paired forget remove"
            case .identity: "device identity id private key paired macs"
            case .developer: "developer plan override debug"
            case .more: "more peering for mac download introduction tips report issue copy diagnostics support help"
            case .legal: "legal privacy policy terms"
            case .sessionInfo: "session mac state path direct video connection latency"
            case .activity: "recent activity log history"
            case .stream: "stream display app window source sound audio mute quality bitrate automatic manual"
            case .sessionPicture: "picture in picture pip float automatically"
            case .sessionPanels: "panels close after selecting"
            case .privacy: "privacy relay allow darken displays brightness privacy mode"
            case .sessionKeyboard: "keyboard unicode keycode open for text fields auto"
            case .macros: "macros shortcuts edit"
            case .pairedMacs: "paired macs trusted forget"
            case .thisDevice: "this device name phone"
            }
        }
    }

    /// Every word typed has to appear somewhere in the section's words.
    static func matches(_ section: Section, _ query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = section.keywords
        return words.allSatisfy { haystack.contains($0) }
    }

    static let tabSections: [Section] = [
        .device, .controls, .quality, .remoteAccess, .security, .pip, .widget, .liveActivity,
        .notifications, .trustedMacs, .identity, .more, .legal,
    ]
    static let panelSections: [Section] = [
        .sessionInfo, .activity, .stream, .sessionPicture, .sessionPanels, .privacy,
        .sessionKeyboard, .macros, .pairedMacs, .thisDevice,
    ]

    /// Whether a screen with these sections has nothing to show for this query.
    static func hasNoMatch(_ query: String, in sections: [Section] = tabSections) -> Bool {
        !sections.contains { matches($0, query) }
    }

    static func noResults(_ query: String) -> some View {
        Text("No settings match “\(query)”")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }
}

/// The search box at the top of a settings screen.
struct SettingsSearchField: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search settings", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .frame(height: 38)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(ColorPalette.ink.opacity(0.14), lineWidth: 1)
        )
    }
}
