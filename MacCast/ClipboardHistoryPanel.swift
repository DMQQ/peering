import RemoteCore
import SwiftUI

/// What has been pulled from the Mac, newest first.
///
/// The Mac's pasteboard holds one thing, so a second Pull replaces the first — this list is the
/// only place the earlier ones still exist. Tapping an entry puts it on this phone, which is what
/// a clipboard list is nearly always for; sending one back the other way is in the row's menu,
/// because it is the rarer of the two by a distance.
///
/// Everything pulled is kept, which is worth saying out loud: clipboard text is as sensitive as
/// whatever was on the Mac at the time, and this is a list of it that survives relaunching the
/// app. It is cleared in one tap from here.
struct ClipboardHistoryPanel: View {
    @Environment(SessionModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var justCopied: UUID?
    @State private var confirmsClear = false

    var body: some View {
        NavigationStack {
            Group {
                if model.clipboardHistory.isEmpty {
                    ContentUnavailableView(
                        "Nothing pulled yet",
                        systemImage: "doc.on.clipboard",
                        description: Text("Pull the Mac's clipboard and it lands here, so the next pull does not lose it.")
                    )
                } else {
                    List(model.clipboardHistory) { entry in
                        row(entry)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Clipboard")
            .navigationBarTitleDisplayMode(.inline)
            // The panel's own colour rather than a bar material over it, for the reason the
            // terminal panel's header is its own colour: two greys stacked read as two apps.
            .toolbarBackground(ColorPalette.backdrop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if !model.clipboardHistory.isEmpty {
                        Button("Clear", role: .destructive) { confirmsClear = true }
                    }
                }
            }
            .confirmationDialog(
                "Clear the clipboard history?",
                isPresented: $confirmsClear,
                titleVisibility: .visible
            ) {
                Button("Clear", role: .destructive) { model.clearClipboardHistory() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The Mac's own clipboard is untouched. This only forgets what this phone kept.")
            }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ entry: SessionModel.ClipboardEntry) -> some View {
        Button {
            model.copyToPhone(entry)
            withAnimation(Motion.tap) { justCopied = entry.id }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                // Three lines, not one. A clipboard is as often a paragraph as a word, and a
                // list of first-lines is a list of nearly identical openings.
                Text(entry.text)
                    .font(.callout)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 5) {
                    Text(entry.at, style: .relative)
                    if justCopied == entry.id {
                        Label("Copied", systemImage: "checkmark")
                            .foregroundStyle(ColorPalette.accent)
                            .transition(.opacity)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Send to Mac", systemImage: "arrow.up.doc") { model.pushToMac(entry) }
                .menuInk()
            Button("Delete", systemImage: "trash", role: .destructive) {
                model.removeClipboardEntry(entry.id)
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) {
                model.removeClipboardEntry(entry.id)
            }
        }
    }
}
