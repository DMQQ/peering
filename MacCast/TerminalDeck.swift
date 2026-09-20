import SSHCore
import SwiftUI
import MacCastKit

/// Everything a shell can be told to do without typing it, in one row.
///
/// **One row, where there were two**, and the reason is what the terminal looked like: the saved
/// commands and the control keys were strips of their own stacked under a third — the input field
/// — and the three of them took a third of the screen and read as three unrelated widgets that
/// happened to be in a column. They are one kind of thing: a chip you tap to send bytes.
///
/// The order inside the row was the only thing that had to be decided. The saved commands come
/// first, because they are the ones not in a place the thumb already knows — the list changes,
/// and a chip the user added themselves is a chip they have to look for. The keys follow in the
/// fixed order they have always had. The cost is that a user with a great many saved commands
/// pushes ⌃C to the right, and that is a real cost; it is paid because the alternative is the
/// second row this exists to remove, and because a command list long enough to matter is its own
/// problem.
///
/// The keys are shared by both terminals and always have been, and why they can be is worth
/// keeping: every escape sequence here is what the *shell* reads, and a shell reads the same bytes
/// whether it is the login shell on a Mac being cast to or a server being SSH'd into.
struct TerminalDeck: View {
    /// The saved commands, and what to do with one.
    let commands: [SSHQuickCommand]
    let run: (SSHQuickCommand) -> Void
    let remove: (SSHQuickCommand) -> Void
    /// What the button at the head of the row does: open the editor.
    ///
    /// **One closure rather than two, because there is one button.** The button that makes a
    /// command and the button that sells the plan to make one are the same button in the same
    /// place, so what the caller hands over is what it does when it is live, and the gate between
    /// that and the plans is ``PlanLocked``'s.
    let edit: () -> Void

    /// Bytes to send to the shell, as a string of them.
    let send: (String) -> Void
    var isEnabled = true

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // Eight rather than six, which is what the browser's row of the same chips uses: the
            // two rows are the same object and a thumb has no way to know they were written a
            // fortnight apart.
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
                // only way to make the first one, and it is drawn on the plans that do not
                // include making one as well: the same slider glyph in the same 46 points,
                // dimmed, with the plan's name beside it. That is how somebody finds out the
                // feature is there to want, and the glyph is what tells them which feature it is.
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
                            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(RailButtonStyle(scale: 0.88))
                    .accessibilityLabel(commands.isEmpty ? "Add a quick command" : "Edit quick commands")
                }

                divider

                // Editing and the shell's own control keys first, then a group of navigation
                // keys, then the two that end a line. The order is the order they are reached
                // for: ⌃C is the one key a phone terminal cannot do without, so it is near the
                // front — see the note on the row itself for the commands sitting in front of it.
                key("esc", label: "Escape", bytes: "\u{1B}")
                key("tab", label: "Tab", bytes: "\t")
                key("⇧tab", label: "Back tab", bytes: "\u{1B}[Z")
                key("⌃C", label: "Interrupt", bytes: "\u{03}")
                key("⌃D", label: "End of input", bytes: "\u{04}")
                key("⌃Z", label: "Suspend", bytes: "\u{1A}")
                key("⌃L", label: "Clear screen", bytes: "\u{0C}")
                key("⌃R", label: "Search history", bytes: "\u{12}")
                key("⌃A", label: "Start of line", bytes: "\u{01}")
                key("⌃E", label: "End of line", bytes: "\u{05}")
                key("⌃K", label: "Delete to end of line", bytes: "\u{0B}")
                key("⌃U", label: "Delete to start of line", bytes: "\u{15}")
                key("⌃W", label: "Delete word before", bytes: "\u{17}")

                divider

                key("↑", label: "Up", bytes: "\u{1B}[A")
                key("↓", label: "Down", bytes: "\u{1B}[B")
                key("←", label: "Left", bytes: "\u{1B}[D")
                key("→", label: "Right", bytes: "\u{1B}[C")
                // Word at a time. Option rather than Control because that is what macOS Terminal
                // binds, and the escape sequences it produces are what bash and zsh read as "a
                // word" — ⌃← would move by a word in some shells and by a character in others.
                key("⌥←", label: "Word left", bytes: "\u{1B}b")
                key("⌥→", label: "Word right", bytes: "\u{1B}f")
                key("home", label: "Home", bytes: "\u{1B}[H")
                key("end", label: "End", bytes: "\u{1B}[F")
                key("pg↑", label: "Page up", bytes: "\u{1B}[5~")
                key("pg↓", label: "Page down", bytes: "\u{1B}[6~")

                divider

                key("ins", label: "Insert", bytes: "\u{1B}[2~")
                key("del", label: "Delete forward", bytes: "\u{1B}[3~")
                key("⌫", label: "Backspace", bytes: "\u{7F}")
                key("return", label: "Return", bytes: "\r")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color.white.opacity(0.05))
        .overlay(alignment: .top) { hairline }
        .disabled(!isEnabled)
    }

    /// One key, drawn by ``TerminalKeyChip`` — which the browser's own row draws too, for the
    /// three keys that have to stay reachable when this row is not on screen.
    private func key(_ title: String, label: String, bytes: String) -> some View {
        TerminalKeyChip(title: title, label: label) { send(bytes) }
    }

    /// Between the groups. The row is long, and a wall of two dozen chips is one a thumb has to
    /// read from the left every time; four groups, split by what they are for, is a row where you
    /// know roughly how far to travel.
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                // Monospaced, because these are the characters the shell prints rather than words:
                // "esc" and "tab" line up with the arrows beside them, and "⌃C" is the same glyph
                // the control bar's caption uses for the same key. A saved command wears it for
                // the same reason a command is read at all: by its shape.
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(ColorPalette.ink)
                .lineLimit(1)
                // Inside the floor rather than outside it, and the order is the whole of this.
                // A key is two or three characters and the 46 points are what give it its shape;
                // a saved command is a word or three, and without this its label runs to the
                // rounded corners of its own tile. Padded *before* the floor, `esc` is still 46
                // and `Memory left` gets the same 9 points of air each side that every other tile
                // has — rather than the keys growing by 18 to pay for the commands' padding.
                .padding(.horizontal, 9)
                .frame(minWidth: 46)
                .frame(height: height)
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(RailButtonStyle(scale: 0.88))
        .accessibilityLabel(label)
    }
}
