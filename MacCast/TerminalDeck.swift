import MacCastKit
import SSHCore
import SwiftUI

/// Everything a shell can be told without typing: the keys used all the time in one row, and under it the quick commands with a button for all the rest.
/// Shared by both terminals: these escape sequences are read by the shell, which reads the same bytes on a Mac or a server.
struct TerminalDeck: View {
    let commands: [SSHQuickCommand]
    let run: (SSHQuickCommand) -> Void
    let remove: (SSHQuickCommand) -> Void
    let edit: () -> Void

    let send: (String) -> Void
    var isEnabled = true

    @State private var showsAllKeys = false
    @AppStorage(PreferenceKeys.terminalTextSize) private var textSize = TerminalMetrics.TextSize.regular.rawValue

    var body: some View {
        mainRow
            .background(Color.black)
            .overlay(alignment: .top) { hairline }
            .disabled(!isEnabled)
            .sheet(isPresented: $showsAllKeys) {
                TerminalAllKeys(
                    commands: commands,
                    run: run,
                    remove: remove,
                    edit: edit,
                    send: send
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(ColorPalette.backdrop)
            }
    }

    // MARK: - Fixed row

    /// One row: the three keys used all the time, the four arrows as one joined group, and a button for everything else. Enter is the send button of the input.
    private var mainRow: some View {
        HStack(spacing: 6) {
            Button { showsAllKeys = true } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ColorPalette.ink)
                    .frame(width: 36, height: 44)
                    .terminalKeyBackground(cornerRadius: 9)
            }
            .buttonStyle(RailButtonStyle(scale: 0.9))
            .accessibilityLabel("More keys and quick commands")

            narrowKey("esc", label: "Escape", bytes: "\u{1B}")
            narrowKey("tab", label: "Tab", bytes: "\t")
            narrowKey("⌃C", label: String(localized: "Interrupt"), bytes: "\u{03}")

            HStack(spacing: 1) {
                arrow("←", label: String(localized: "Left"), bytes: "\u{1B}[D")
                arrow("↑", label: String(localized: "Up"), bytes: "\u{1B}[A")
                arrow("↓", label: String(localized: "Down"), bytes: "\u{1B}[B")
                arrow("→", label: String(localized: "Right"), bytes: "\u{1B}[C")
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func arrow(_ title: String, label: String, bytes: String) -> some View {
        Button { send(bytes) } label: {
            Text(title)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(ColorPalette.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Color.white.opacity(0.10))
        }
        .buttonStyle(RailButtonStyle(scale: 0.92))
        .accessibilityLabel(label)
    }

    // MARK: - Helpers

    private func key(_ title: String, label: String, bytes: String) -> some View {
        TerminalKeyChip(title: title, label: label) { send(bytes) }
    }

    private func narrowKey(_ title: String, label: String, bytes: String) -> some View {
        TerminalKeyChip(title: title, label: label, height: 44, width: 38) { send(bytes) }
    }

    private func flexKey(_ title: String, label: String, bytes: String) -> some View {
        TerminalKeyChip(title: title, label: label, flexible: true) { send(bytes) }
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
    /// A fixed width, for a key that should leave the room to its neighbours.
    var width: CGFloat?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(ColorPalette.ink)
                .lineLimit(1)
                .padding(.horizontal, flexible || width != nil ? 2 : 9)
                .frame(minWidth: flexible || width != nil ? nil : 46, maxWidth: flexible ? .infinity : nil)
                .frame(width: width)
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

/// One view for both terminals, at the end of the command capsule while the keyboard is up.
struct TerminalHideKeyboardKey: View {
    var body: some View {
        Button {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        } label: {
            Image(systemName: "keyboard.chevron.compact.down")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Hide keyboard")
        .transition(.opacity.combined(with: .scale(scale: 0.8)))
    }
}

/// Every key the deck leaves out, grouped by what it does and named in words, since `⌃K` on its own says little.
private struct TerminalAllKeys: View {
    let commands: [SSHQuickCommand]
    let run: (SSHQuickCommand) -> Void
    let remove: (SSHQuickCommand) -> Void
    let edit: () -> Void
    let send: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(PreferenceKeys.terminalTextSize) private var textSize = TerminalMetrics.TextSize.regular.rawValue

    private struct Group: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let keys: [(title: String, label: String, bytes: String)]
    }

    private var groups: [Group] {
        [
            Group(id: "move", title: "Move the cursor", keys: [
                ("⌥←", String(localized: "Word left"), "\u{1B}b"),
                ("⌥→", String(localized: "Word right"), "\u{1B}f"),
                ("⌃A", String(localized: "Start of line"), "\u{01}"),
                ("⌃E", String(localized: "End of line"), "\u{05}")
            ]),
            Group(id: "delete", title: "Delete", keys: [
                ("⌫", String(localized: "Backspace"), "\u{7F}"),
                ("del", String(localized: "Delete forward"), "\u{1B}[3~"),
                ("⌃W", String(localized: "Delete word before"), "\u{17}"),
                ("⌃U", String(localized: "Delete to start of line"), "\u{15}"),
                ("⌃K", String(localized: "Delete to end of line"), "\u{0B}")
            ]),
            Group(id: "session", title: "Shell and programs", keys: [
                ("⌃D", String(localized: "End of input"), "\u{04}"),
                ("⌃Z", String(localized: "Suspend"), "\u{1A}"),
                ("⌃L", String(localized: "Clear screen"), "\u{0C}"),
                ("⌃R", String(localized: "Search history"), "\u{12}"),
                ("⇧tab", String(localized: "Back tab"), "\u{1B}[Z")
            ]),
            Group(id: "page", title: "Pages and ends", keys: [
                ("home", String(localized: "Home"), "\u{1B}[H"),
                ("end", "End", "\u{1B}[F"),
                ("pg↑", String(localized: "Page up"), "\u{1B}[5~"),
                ("pg↓", String(localized: "Page down"), "\u{1B}[6~"),
                ("ins", String(localized: "Insert"), "\u{1B}[2~")
            ])
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                quickCommands
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(group.title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                            ForEach(group.keys, id: \.title) { key in
                                Button { send(key.bytes) } label: {
                                    HStack(spacing: 10) {
                                        Text(key.title)
                                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(ColorPalette.ink)
                                            .frame(minWidth: 40)
                                            .padding(.vertical, 6)
                                            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                        Text(key.label)
                                            .font(.footnote)
                                            .foregroundStyle(.white.opacity(0.75))
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(8)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .strokeBorder(.white.opacity(0.14))
                                    }
                                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(RailButtonStyle(scale: 0.96))
                                .accessibilityLabel(key.label)
                            }
                        }
                    }
                }
            }
            .padding(16)
            textSizeRow
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
        }
    }

    private var quickCommands: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick commands")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                ForEach(commands) { command in
                    Button {
                        dismiss()
                        run(command)
                    } label: {
                        Text(command.displayTitle)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(ColorPalette.ink)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.14))
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(RailButtonStyle(scale: 0.95))
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) { remove(command) }
                            .menuDanger()
                    }
                }
                // Drawn even when nothing is saved, and dimmed with the plan name on restricted plans, so the feature is discoverable.
                PlanLocked(
                    capability: .macros,
                    title: commands.isEmpty ? "Add a quick command" : "Edit quick commands",
                    diameter: 40
                ) {
                    Button {
                        dismiss()
                        edit()
                    } label: {
                        Label(commands.isEmpty ? "Add" : "Edit", systemImage: commands.isEmpty ? "plus" : "slider.horizontal.3")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(ColorPalette.ink)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(.white.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(RailButtonStyle(scale: 0.95))
                }
            }
        }
    }

    private var textSizeRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Text size")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("Terminal text size", selection: $textSize) {
                ForEach(TerminalMetrics.TextSize.allCases) { size in
                    Text(size.name).tag(size.rawValue)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}
