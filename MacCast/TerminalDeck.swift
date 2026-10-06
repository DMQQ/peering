import MacCastKit
import SSHCore
import SwiftUI

/// Everything a shell can be told without typing, in two rows: eight fixed keys, and a scrolling row of quick commands and less urgent keys.
/// Shared by both terminals: these escape sequences are read by the shell, which reads the same bytes on a Mac or a server.
struct TerminalDeck: View {
    let commands: [SSHQuickCommand]
    let run: (SSHQuickCommand) -> Void
    let remove: (SSHQuickCommand) -> Void
    let edit: () -> Void

    let send: (String) -> Void
    var isEnabled = true

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

    private var fixedRow: some View {
        HStack(spacing: 6) {
            flexKey("enter", label: "Enter", bytes: "\r")
            flexKey("⌃C", label: String(localized: "Interrupt"), bytes: "\u{03}")
            flexKey("tab", label: "Tab", bytes: "\t")
            flexKey("esc", label: "Escape", bytes: "\u{1B}")
            flexKey("↑", label: "Up", bytes: "\u{1B}[A")
            flexKey("↓", label: String(localized: "Down"), bytes: "\u{1B}[B")
            flexKey("←", label: String(localized: "Left"), bytes: "\u{1B}[D")
            flexKey("→", label: String(localized: "Right"), bytes: "\u{1B}[C")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) { hairline }
    }

    // MARK: - Scrollable row

    private var scrollableRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(commands) { command in
                    TerminalKeyChip(
                        title: command.displayTitle,
                        label: String(localized: "Run \(command.command)")
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

                // Drawn even when nothing is saved, and dimmed with the plan name on restricted plans, so the feature is discoverable.
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

                // Option, not Control: that is what macOS Terminal binds, and the sequences are what bash and zsh read as a word.
                key("⌥←", label: String(localized: "Word left"), bytes: "\u{1B}b")
                key("⌥→", label: String(localized: "Word right"), bytes: "\u{1B}f")

                divider

                key("⌃A", label: String(localized: "Start of line"), bytes: "\u{01}")
                key("⌃E", label: String(localized: "End of line"), bytes: "\u{05}")
                key("⌃K", label: String(localized: "Delete to end of line"), bytes: "\u{0B}")
                key("⌃U", label: String(localized: "Delete to start of line"), bytes: "\u{15}")
                key("⌃W", label: String(localized: "Delete word before"), bytes: "\u{17}")
                key("⌫", label: String(localized: "Backspace"), bytes: "\u{7F}")
                key("⌃D", label: String(localized: "End of input"), bytes: "\u{04}")
                key("⌃Z", label: String(localized: "Suspend"), bytes: "\u{1A}")
                key("⌃L", label: String(localized: "Clear screen"), bytes: "\u{0C}")
                key("⌃R", label: String(localized: "Search history"), bytes: "\u{12}")
                key("⇧tab", label: String(localized: "Back tab"), bytes: "\u{1B}[Z")

                divider

                key("home", label: String(localized: "Home"), bytes: "\u{1B}[H")
                key("end", label: "End", bytes: "\u{1B}[F")
                key("pg↑", label: String(localized: "Page up"), bytes: "\u{1B}[5~")
                key("pg↓", label: String(localized: "Page down"), bytes: "\u{1B}[6~")
                key("ins", label: String(localized: "Insert"), bytes: "\u{1B}[2~")
                key("del", label: String(localized: "Delete forward"), bytes: "\u{1B}[3~")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Helpers

    private func key(_ title: String, label: String, bytes: String) -> some View {
        TerminalKeyChip(title: title, label: label) { send(bytes) }
    }

    private func flexKey(_ title: String, label: String, bytes: String) -> some View {
        TerminalKeyChip(title: title, label: label, flexible: true) { send(bytes) }
    }

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

/// One chip, written (`esc`, `⌃C`) in the notation a shell prints. Its own view because the file browser shows three of these keys while the deck is away.
struct TerminalKeyChip: View {
    let title: String
    let label: String
    var height: CGFloat = 40
    var flexible: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
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

/// One view for both terminals, drawn as a key at the height of its row.
struct TerminalHideKeyboardKey: View {
    /// Handed in so each terminal keeps its own way of letting go of the field.
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "keyboard.chevron.compact.down")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ColorPalette.ink)
                .frame(width: 46, height: 30)
                .terminalKeyBackground(cornerRadius: 7)
        }
        .buttonStyle(RailButtonStyle(scale: 0.88))
        .accessibilityLabel("Hide keyboard")
    }
}
