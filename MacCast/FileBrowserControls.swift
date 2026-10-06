import SwiftUI

/// The switch between a shell and the machine's folders, pinned at the end of the tab strip. A bare glyph in the input row read as one more terminal key, and in the navigation bar beside the back button it read as a breadcrumb. The strip is drawn in both modes, and a chip matches the deck's buttons.
/// The label names where the button goes ("Files" from the shell, "Shell" from the folders).
struct TerminalModeButton: View {
    let isBrowsing: Bool
    /// False in a navigation bar, which already draws a surface behind it: two stacked glasses make a double edge.
    var carriesOwnSurface = true
    let action: () -> Void

    var body: some View {
        // Sized to the tab strip (26 points, against the deck's 40): a taller chip would push the tabs off their seam.
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isBrowsing ? "terminal" : "folder")
                    .font(.system(size: 11, weight: .semibold))
                Text(isBrowsing ? "Shell" : "Files")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isBrowsing ? ColorPalette.accent : ColorPalette.ink)
            .lineLimit(1)
            .padding(.horizontal, carriesOwnSurface ? 10 : 0)
            .frame(height: 26)
            .modifier(ModeButtonSurface(carriesOwnSurface: carriesOwnSurface))
        }
        .buttonStyle(RailButtonStyle(scale: 0.88))
        .accessibilityLabel(isBrowsing ? "Shell" : "Files")
        .accessibilityHint(isBrowsing ? "Shows the shell" : "Browses the files on this machine")
    }
}

private struct ModeButtonSurface: ViewModifier {
    let carriesOwnSurface: Bool

    func body(content: Content) -> some View {
        if carriesOwnSurface {
            content.glassSurface(in: RoundedRectangle(cornerRadius: 8, style: .continuous), interactive: true)
        } else {
            content
        }
    }
}

/// The row under a file browser, shared by both browsers: everything they differ by is a closure. The switch back to the shell lives in the navigation bar, since two labelled buttons left the command field nowhere to type.
struct FileBrowseBar: View {
    let isEnabled: Bool
    let showsHidden: Bool

    /// False for the hub's browser, which has no shell to send keys to.
    var showsKeys = true

    var onInterrupt: () -> Void
    var onEscape: () -> Void
    var onTab: () -> Void
    var onReload: () -> Void
    var onToggleHidden: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // The three keys worth having while the key strip is away: Ctrl-C first, because a command flooding output does not stop for folders, then esc and tab.
            if showsKeys {
                TerminalKeyChip(title: "⌃C", label: String(localized: "Interrupt"), height: 30, action: onInterrupt)
                TerminalKeyChip(title: "esc", label: String(localized: "Escape"), height: 30, action: onEscape)
                TerminalKeyChip(title: "tab", label: String(localized: "Tab"), height: 30, action: onTab)

                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
            }

            icon("arrow.clockwise", label: String(localized: "Reload this folder"), action: onReload)

            icon(
                showsHidden ? "eye" : "eye.slash",
                label: showsHidden ? String(localized: "Hide hidden files") : String(localized: "Show hidden files"),
                isOn: showsHidden,
                action: onToggleHidden
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black)
        .overlay(alignment: .top) { hairline }
        .disabled(!isEnabled)
    }

    private func icon(
        _ symbol: String,
        label: String,
        isOn: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isOn ? ColorPalette.accent : Color.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var hairline: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
    }
}
