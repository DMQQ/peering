import SSHCore
import SwiftUI

/// Text, not `Macro`: a Macro is a macOS virtual keycode and means nothing to a Linux box.
struct SSHQuickCommandsEditor: View {
    let commands: QuickCommands

    @Environment(\.dismiss) private var dismiss
    @State private var editing: SSHQuickCommand?
    @State private var isAdding = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackdrop()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if commands.all.isEmpty {
                            emptyCard
                        } else {
                            Controls.card(String(localized: "Saved")) {
                                VStack(spacing: 0) {
                                    ForEach(Array(commands.all.enumerated()), id: \.element.id) { index, quick in
                                        row(quick)
                                        if index < commands.all.count - 1 {
                                            Controls.divider
                                        }
                                    }
                                }
                            }
                        }

                        Button {
                            isAdding = true
                        } label: {
                            Label("Add a command", systemImage: "plus")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(ColorPalette.accent)
                        .foregroundStyle(.white)
                    }
                    .padding(18)
                }
            }
            .navigationTitle("Quick Commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $isAdding) {
                SSHQuickCommandSheet(existing: nil) { commands.save($0) }
            }
            .sheet(item: $editing) { quick in
                SSHQuickCommandSheet(existing: quick) { commands.save($0) }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            IconTile(symbol: "text.badge.plus")
            Text("No commands yet")
                .font(.subheadline.weight(.semibold))
            Text("Anything you type often: a log tail, a restart, a jump to a directory. Saved commands appear as chips above the keyboard while a shell is open.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func row(_ quick: SSHQuickCommand) -> some View {
        Button {
            editing = quick
        } label: {
            HStack(spacing: 11) {
                Controls.icon("terminal")

                VStack(alignment: .leading, spacing: 2) {
                    Text(quick.displayTitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(ColorPalette.ink)
                        .lineLimit(1)
                    Text(quick.command)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 10)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete", systemImage: "trash", role: .destructive) { commands.delete(quick) }
                .menuDanger()
        }
    }
}

struct SSHQuickCommandSheet: View {
    let existing: SSHQuickCommand?
    let onSave: (SSHQuickCommand) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var command: String

    init(existing: SSHQuickCommand?, onSave: @escaping (SSHQuickCommand) -> Void) {
        self.existing = existing
        self.onSave = onSave
        _title = State(initialValue: existing?.title ?? "")
        _command = State(initialValue: existing?.command ?? "")
    }

    private var canSave: Bool {
        !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Controls.card(
                    String(localized: "Command"),
                    footer: String(localized: "Name is what the chip says. Leave it empty and the first word of the command is used instead.")
                ) {
                    VStack(spacing: 10) {
                        Controls.row(String(localized: "Name"), systemImage: "tag") {
                            TextField("Optional", text: $title)
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(ColorPalette.ink)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        Controls.divider
                        HStack(spacing: 11) {
                            Controls.icon("terminal")
                            // Autocorrect off: iOS capitalising `docker ps` yields a command that does not exist.
                            TextField("docker ps", text: $command)
                                .font(.system(.subheadline, design: .monospaced))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }
                }

                Button {
                    commit()
                } label: {
                    Text(existing == nil ? "Add command" : "Save changes")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(ColorPalette.accent)
                .foregroundStyle(.white)
                .disabled(!canSave)

                Spacer(minLength: 0)
            }
            .padding(18)
            .background(ColorPalette.backdrop)
            .navigationTitle(existing == nil ? "New Command" : "Edit Command")
            .navigationBarTitleDisplayMode(.inline)
            .sheetToolbar(onCancel: { dismiss() })
        }
        .presentationDetents([.height(400)])
        .preferredColorScheme(.dark)
    }

    private func commit() {
        guard canSave else { return }
        var quick = existing ?? SSHQuickCommand(title: "", command: "")
        quick.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        quick.command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(quick)
        dismiss()
    }
}
