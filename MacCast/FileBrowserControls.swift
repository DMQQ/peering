import SwiftUI

/// The switch between a shell and the machine's folders, pinned at the far end of the tab strip.
///
/// **The word is the whole of the change**, and it is worth saying what was wrong without one.
/// This was a bare folder glyph sitting in the input row among other bare glyphs, wearing the
/// accent while it was on and nothing while it was off — and a glyph of the same weight and colour
/// as the controls beside it, at the bottom of a terminal, does not read as "there is a file
/// browser in here". It reads as one more terminal key. The user who reported it had no idea the
/// browser existed, which is the failure mode of an icon: it names a thing to somebody who already
/// knows what it is.
///
/// So it was given its word, and then the word cost too much: labelled, it was 86 points of a row
/// that also has to hold everything the user types. That sent it to the navigation bar, which had
/// room — and that is where it read wrong. The leading end of a bar is where a back button lives,
/// so a folder glyph and the word "Files" sitting beside "‹ Servers" reads as a breadcrumb: *you
/// are here*, a statement about the screen, rather than a control that does anything. The user
/// reported exactly that.
///
/// It is here now because the tab strip is the row that already answers "which of these am I
/// looking at", and shell-versus-folders is that same question one axis over — the chip reads as
/// one more thing to look at rather than as chrome about the screen. Three things made the strip
/// the right row and not just a different one: it is drawn in **both** modes, which the deck is
/// not (it is hidden while browsing, so the way back could not live in it) and which the browser's
/// own bar deliberately is not; pinned outside the scroller it **stays put** however many shells
/// are open; and a chip is the shape the deck below it already uses for "a button you tap", so it
/// is not teaching a second vocabulary for the same gesture.
///
/// The label names where the button *goes* rather than where it is, because that is the question a
/// button answers: "Files" while the shell is on screen, "Shell" while the folders are. "Shell"
/// rather than "Terminal" because that is what this screen calls them — the tab beside it is a
/// shell, and the button that makes one says "New shell" — and because the word is competing with
/// the tabs for a narrow row.
struct TerminalModeButton: View {
    /// Whether the folders are on screen. What the button then says is where tapping goes next.
    let isBrowsing: Bool
    let action: () -> Void

    var body: some View {
        // Sized to the tab strip rather than to the deck: 26 points against the deck's 40, because
        // the row it sits in is a tab strip that is the height of its tabs and a chip that set the
        // height of that row would push the tabs apart from the seam they sit on.
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isBrowsing ? "terminal" : "folder")
                    .font(.system(size: 11, weight: .semibold))
                Text(isBrowsing ? "Shell" : "Files")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isBrowsing ? ColorPalette.accent : ColorPalette.ink)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .glassSurface(in: RoundedRectangle(cornerRadius: 8, style: .continuous), interactive: true)
        }
        .buttonStyle(RailButtonStyle(scale: 0.88))
        .accessibilityLabel(isBrowsing ? "Shell" : "Files")
        .accessibilityHint(isBrowsing ? "Shows the shell" : "Browses the files on this machine")
    }
}

/// The row under a file browser: the keys a shell still needs, and what can be done with the list.
///
/// Shared by both browsers rather than written twice, and there is a reason it can be. Everything
/// the two rows differ by is a closure: what a reload asks, and which machine it asks it of. That
/// is the same split ``FileBrowserPanel`` makes for the list itself, one row further down.
///
/// The switch back to the shell is not on it. It was, as a labelled chip at the leading end, and
/// the label did its job — but two buttons wide enough to read, side by side with the command
/// field, is a field with nowhere to type. It lives in the navigation bar now, on both screens,
/// which is where a control that says *which screen is this* belongs anyway.
struct FileBrowseBar: View {
    /// Whether the shell behind the browser will take anything at all. A session that has ended
    /// takes no keys and no reloads, and a row of live controls over a socket that is gone is a row
    /// of controls that do nothing when pressed.
    let isEnabled: Bool
    let showsHidden: Bool

    var onInterrupt: () -> Void
    var onEscape: () -> Void
    var onTab: () -> Void
    var onReload: () -> Void
    var onToggleHidden: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // The three keys that are still worth having while the key strip is away. ⌃C first,
            // because a command that is filling the screen with output does not stop because the
            // screen is showing folders — and `esc` and `tab` beside it, which are the two keys a
            // shell is driven with before any of the others: one to back out of what is running,
            // one to finish a name instead of typing it.
            TerminalKeyChip(title: "⌃C", label: String(localized: "Interrupt"), height: 30, action: onInterrupt)
            TerminalKeyChip(title: "esc", label: String(localized: "Escape"), height: 30, action: onEscape)
            TerminalKeyChip(title: "tab", label: String(localized: "Tab"), height: 30, action: onTab)

            Spacer(minLength: 0)

            // Reload, which until now lived only inside the failure state — so the one way to ask
            // a folder for a second look was to have it fail to answer the first time.
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

    /// One of the two controls at the trailing end, which are buttons rather than keys and are
    /// drawn as the other panels' icon buttons are: no tile, and the accent when they are on.
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

    /// The line between this band of the browser and the list above it, at the one weight every
    /// seam in either terminal is drawn at — see ``TerminalPanel/hairline``.
    private var hairline: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
    }
}
