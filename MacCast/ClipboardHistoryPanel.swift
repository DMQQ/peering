import RemoteCore
import SwiftUI

/// What has been pulled from the Mac, newest first.
///
/// The Mac's pasteboard holds one thing, so a second pull replaces the first, and this list is the
/// only place the earlier ones still exist. Tapping an entry puts it on this phone, which is what
/// a clipboard list is nearly always for; sending one back the other way is in the row's menu,
/// because it is the rarer of the two by a distance.
///
/// Everything pulled is kept, which is worth saying out loud: clipboard text is as sensitive as
/// whatever was on the Mac at the time, and this is a list of it that survives relaunching the
/// app. It is cleared in one tap from here.
struct ClipboardHistoryPanel: View {
    var onBack: () -> Void
    @Environment(SessionModel.self) private var model
    @State private var justCopied: UUID?
    @State private var confirmsClear = false

    var body: some View {
        VStack(spacing: 8) {
            header
            if model.clipboardHistory.isEmpty {
                Text("Text copied from the Mac lands here, so the next copy does not lose it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.clipboardHistory) { entry in
                            row(entry)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: 340)
                .fixedSize(horizontal: false, vertical: true)
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
            Text("The Mac's own clipboard is untouched. This only forgets what this device kept.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                    Text("History")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(ColorPalette.ink)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(RailButtonStyle(scale: 0.96))
            .accessibilityLabel("Back to clipboard")

            Spacer(minLength: 10)

            if !model.clipboardHistory.isEmpty {
                Button("Clear", role: .destructive) { confirmsClear = true }
                    .font(.subheadline.weight(.medium))
            }
        }
        .padding(.horizontal, 4)
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
            .padding(10)
            .contentShape(Rectangle())
            .rowSurface()
        }
        .buttonStyle(RailButtonStyle(scale: 0.98))
        .contextMenu {
            Button("Send to Mac", systemImage: "arrow.up.doc") { model.pushToMac(entry) }
                .menuInk()
            Button("Delete", systemImage: "trash", role: .destructive) {
                model.removeClipboardEntry(entry.id)
            }
            .menuDanger()
        }
    }
}
