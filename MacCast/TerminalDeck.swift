import MacCastKit
import SSHCore
import SwiftUI

/// Everything a shell can be told to do without typing it, in two rows.
///
/// **Two rows.** The first is fixed across the full width: the eight keys that a phone terminal
/// reaches for most, always visible without scrolling — return and the four arrows you want the
/// moment a program asks a question, flanked by the two that cancel things and the two that
/// navigate menus. The second scrolls, holding quick commands and the keys that are useful but
/// not instant-reach: word jumps, line-editing sequences, and the navigation cluster.
///
/// The keys are shared by both terminals and always have been, and why they can be is worth
/// keeping: every escape sequence here is what the *shell* reads, and a shell reads the same bytes
/// whether it is the login shell on a Mac being cast to or a server being SSH'd into.
struct TerminalDeck: View {
    /// The saved commands, and what to do with one.
    let commands: [SSHQuickCommand]
    let run: (SSHQuickCommand) -> Void
    let remove: (SSHQuickCommand) -> Void
    /// What the button at the head of the scrollable row does: open the editor.
    ///
    /// **One closure rather than two, because there is one button.** The button that makes a
    /// command and the button that sells the plan to make one are the same button in the same
    /// place, so what the caller hands over is what it does when it is live, and the gate between
    /// that and the plans is ``PlanLocked``'s.
    let edit: () -> Void

    /// Bytes to send to the shell, as a string of them.
    let send: (String) -> Void
    var isEnabled = true

    /// The type size, which both terminals draw at. See the menu in ``scrollableRow``.
    @AppStorage(PreferenceKeys.terminalTextSize) private var textSize = TerminalMetrics.TextSize.regular.rawValue

    var body: some View {
        VStack(spacing: 0) {
            fixedRow
            scrollableRow
        }
        .background(Color.white.opacity(0.05))
        .overlay(alignment: .top) { hairline }
        .disabled(!isEnabled)
    }

    // MARK: - Fixed row

    /// The eight keys a phone terminal reaches for most, stretched to fill the full width so every
    /// one of them is visible and tappable without scrolling.
    private var fixedRow: some View {
        HStack(spacing: 6) {
            // Sending a bare newline to a running program, confirming a prompt, or running the
            // command the user just typed in with the key strip rather than the field.
            flexKey("enter", label: "Enter", bytes: "\r")
            flexKey("⌃C", label: "Interrupt", bytes: "\u{03}")
            flexKey("tab", label: "Tab", bytes: "\t")
            flexKey("esc", label: "Escape", bytes: "\u{1B}")
            // History (↑↓) and cursor (←→). Reaching for history is the first thing a phone
            // keyboard cannot do that a physical one can, so those two sit before the cursor pair.
            flexKey("↑", label: "Up", bytes: "\u{1B}[A")
            flexKey("↓", label: "Down", bytes: "\u{1B}[B")
            flexKey("←", label: "Left", bytes: "\u{1B}[D")
            flexKey("→", label: "Right", bytes: "\u{1B}[C")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) { hairline }
    }

    // MARK: - Scrollable row

    /// Quick commands and the remaining keys that are useful but not instant-reach.
    private var scrollableRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(commands) { command in
                    TerminalKeyChip(
                        title: command.displayTitle,
                        label: "Run \(command.command)"
                    ) {
                        run(command)
                    }
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            remove(command)
                        }
                        .menuDanger()
                    }
                }

                // Drawn even when there is nothing saved. A control that appears only once you
                // already have one teaches nothing the first time it is needed, and this is the
                // only way to make the first one. Drawn on restricted plans as the same glyph,
                // dimmed, with the plan name on its corner — so the feature is discoverable whether
                // or not the plan covers making one.
                PlanLocked(
                    capability: .macros,
                    title: commands.isEmpty ? "Add a quick command" : "Edit quick commands",
                    diameter: 40
                ) {
                    Button(action: edit) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(ColorPalette.ink)
                            .frame(width: 46, height: 40)
                            .terminalKeyBackground(cornerRadius: 10)
                    }
                    .buttonStyle(RailButtonStyle(scale: 0.88))
                    .accessibilityLabel(commands.isEmpty ? "Add a quick command" : "Edit quick commands")
                }

                // The type size, and it belongs in this row because it is the one control here that
                // is not about what the shell is told: how much of a shell fits across a phone is
                // the type size and the screen, and only one of those is the user's to change. Both
                // terminals read the same preference, so this is the size in both of them.
                Menu {
                    ForEach(TerminalMetrics.TextSize.allCases) { size in
                        Button {
                            textSize = size.rawValue
                        } label: {
                            if textSize == size.rawValue {
                                Label(size.name, systemImage: "checkmark")
                            } else {
                                Text(size.name)
                            }
                        }
                    }
                } label: {
                    Text("Aa")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(ColorPalette.ink)
                        .frame(width: 46, height: 40)
                        .terminalKeyBackground(cornerRadius: 10)
                }
                .menuInk()
                .accessibilityLabel("Terminal text size")

                divider

                // Word jumps first: the closest things to the fixed row's arrow keys.
                // Option rather than Control because that is what macOS Terminal binds, and the
                // escape sequences it produces are what bash and zsh read as "a word".
                key("⌥←", label: "Word left", bytes: "\u{1B}b")
                key("⌥→", label: "Word right", bytes: "\u{1B}f")

                divider

                // Line-editing control sequences.
                key("⌃A", label: "Start of line", bytes: "\u{01}")
                key("⌃E", label: "End of line", bytes: "\u{05}")
                key("⌃K", label: "Delete to end of line", bytes: "\u{0B}")
                key("⌃U", label: "Delete to start of line", bytes: "\u{15}")
                key("⌃W", label: "Delete word before", bytes: "\u{17}")
                key("⌫", label: "Backspace", bytes: "\u{7F}")
                key("⌃D", label: "End of input", bytes: "\u{04}")
                key("⌃Z", label: "Suspend", bytes: "\u{1A}")
                key("⌃L", label: "Clear screen", bytes: "\u{0C}")
                key("⌃R", label: "Search history", bytes: "\u{12}")
                key("⇧tab", label: "Back tab", bytes: "\u{1B}[Z")

                divider

                // Navigation and editing keys that a phone keyboard cannot produce.
                key("home", label: "Home", bytes: "\u{1B}[H")
                key("end", label: "End", bytes: "\u{1B}[F")
                key("pg↑", label: "Page up", bytes: "\u{1B}[5~")
                key("pg↓", label: "Page down", bytes: "\u{1B}[6~")
                key("ins", label: "Insert", bytes: "\u{1B}[2~")
                key("del", label: "Delete forward", bytes: "\u{1B}[3~")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Helpers

    private func key(_ title: String, label: String, bytes: String) -> some View {
        TerminalKeyChip(title: title, label: label) { send(bytes) }
    }

    /// A key that fills an equal share of the fixed row's width.
    private func flexKey(_ title: String, label: String, bytes: String) -> some View {
        TerminalKeyChip(title: title, label: label, flexible: true) { send(bytes) }
    }

    /// Between groups in the scrollable row. A wall of two dozen chips is one a thumb has to
    /// read from the left every time; groups split by purpose give it a rough map.
    private var divider: some View {
        Rectangle()
            .frame(width: 1, height: 22)
            .foregroundStyle(.white.opacity(0.15))
            .padding(.horizontal, 2)
    }

    private var hairline: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
    }
}

/// One chip. Written rather than drawn — `esc`, `⌃C` and `pg↑` are the notation a shell already
/// prints and a keyboard already carries, where a glyph for "page up" is a picture of nothing
/// anyone has seen.
///
/// A view of its own rather than a method of the deck, because the deck is not the only place a
/// chip appears: the file browser keeps three of these keys on screen while the rest of the deck
/// is away, and two spellings of a key is how the two come to look like different things.
struct TerminalKeyChip: View {
    let title: String
    let label: String
    /// The deck's chips are a full row's height; the browser's row is the terminal's input row,
    /// which is a shorter one.
    var height: CGFloat = 40
    /// When true, the chip fills its share of an `HStack`'s available width rather than sizing
    /// to its content. Used by the fixed row in ``TerminalDeck``, where all eight keys divide
    /// the screen equally.
    var flexible: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                // Monospaced, because these are the characters the shell prints rather than words:
                // "esc" and "tab" line up with the arrows beside them, and "⌃C" is the same glyph
                // the control bar's caption uses for the same key.
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(ColorPalette.ink)
                .lineLimit(1)
                .padding(.horizontal, flexible ? 2 : 9)
                .frame(minWidth: flexible ? nil : 46, maxWidth: flexible ? .infinity : nil)
                .frame(height: height)
                .terminalKeyBackground(cornerRadius: 7)
        }
        .buttonStyle(RailButtonStyle(scale: 0.88))
        .accessibilityLabel(label)
    }
}

private extension View {
    /// The flat tile a terminal key wears. No glass, no blur — the terminal is black and the keys
    /// are dark tiles on it, the same material at a different brightness.
    func terminalKeyBackground(cornerRadius: CGFloat) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.10))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
                }
        }
    }
}

/// The key that puts the software keyboard away.
///
/// **One view, because there are two terminals and this is one control.** Their input rows are
/// written separately, being two screens, and the copy that lived in each of them was a bare glyph
/// standing in a row of tiles: the deck above it, the browser's own keys, and the Mac's terminal
/// as much as a server's. It is a key, so it is drawn as one, at the height of the row it stands in.
struct TerminalHideKeyboardKey: View {
    /// What putting the keyboard away means here, which is the one act both terminals agree about:
    /// letting go of the field. Handed in rather than done here, so this stays a key rather than a
    /// behaviour, and so the Mac's terminal and a server's keep their own way of doing it.
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "keyboard.chevron.compact.down")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ColorPalette.ink)
                // The browser row's key, which is the deck's tile at the height of an input row.
                // See ``TerminalKeyChip/height``.
                .frame(width: 46, height: 30)
                .terminalKeyBackground(cornerRadius: 7)
        }
        .buttonStyle(RailButtonStyle(scale: 0.88))
        .accessibilityLabel("Hide keyboard")
    }
}
