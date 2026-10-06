import SwiftUI

/// By section rather than by row: each card keeps its title and footer, so a match still says where the setting lives.
enum SettingsSearch {
    enum Section: CaseIterable {
        case device, controls, quality, remoteAccess, security, pip, widget, liveActivity
        case notifications, trustedMacs, identity, developer, more, legal
        case sessionInfo, activity, stream, sessionPicture, sessionPanels, privacy
        case sessionKeyboard, macros, pairedMacs, thisDevice

        var keywords: String {
            switch self {
            case .device: String(localized: "this device name phone")
            case .controls: String(localized: "session controls interaction observe control picture fit fill keyboard unicode keycode open keyboard text fields close panels after selecting")
            case .quality: String(localized: "stream quality bitrate resolution video auto")
            case .remoteAccess: String(localized: "remote access relay privacy mode internet away upgrade pro")
            case .security: String(localized: "security face id touch id biometric unlock lock passcode privacy analytics usage statistics anonymous")
            case .pip: String(localized: "picture in picture pip float automatically floating window")
            case .widget: String(localized: "home screen widget")
            case .liveActivity: String(localized: "live activity lock screen dynamic island")
            case .notifications: String(localized: "notifications terminal needs you alerts push reached")
            case .trustedMacs: String(localized: "trusted macs paired forget remove")
            case .identity: String(localized: "device identity id private key paired macs")
            case .developer: String(localized: "developer plan override debug")
            case .more: String(localized: "more peering for mac download introduction tips report issue copy diagnostics support help")
            case .legal: String(localized: "legal privacy policy terms")
            case .sessionInfo: String(localized: "session mac state path direct video connection latency")
            case .activity: String(localized: "recent activity log history")
            case .stream: String(localized: "stream display app window source sound audio mute quality bitrate automatic manual")
            case .sessionPicture: String(localized: "picture in picture pip float automatically")
            case .sessionPanels: String(localized: "panels close after selecting")
            case .privacy: String(localized: "privacy relay allow darken displays brightness privacy mode")
            case .sessionKeyboard: String(localized: "keyboard unicode keycode open for text fields auto")
            case .macros: String(localized: "macros shortcuts edit")
            case .pairedMacs: String(localized: "paired macs trusted forget")
            case .thisDevice: String(localized: "this device name phone")
            }
        }
    }

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
