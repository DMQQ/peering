import RemoteCore
import SwiftUI
import UniformTypeIdentifiers
import MacCastKit
import os

private let panelLog = Logger(subsystem: "pl.dmq.peering", category: "file-browser")

/// Reading and editing share one renderer (``MonospacedTextSurface``), one flag apart, so wrapping is the user's choice rather than a mode's side effect. The kind (picture or text) arrives with the bytes (``RemoteFileKind``).
/// A file cut short at the read cap cannot be edited or downloaded, since both would act on 128 KB as though it were the file. See ``SSHModel/saveFile(_:sessionID:)`` for the guard enforced there as well.
struct FilePreviewPanel: View {
    let preview: RemoteFilePreview
    let failure: String?
    var isSaving: Bool = false
    var saveFailure: String?

    var onRevealPath: ((String) -> Void)?
    var onClose: () -> Void
    /// Absent only for a shell that has ended: a pencil would open an editor whose Save could never land.
    var onSave: ((String) -> Void)?

    @State var edited: String?
    @State var shareURL: URL?
    @State var wraps = true

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(ColorPalette.backdrop)
        // Prepared on arrival: the share sheet reads the file as it opens, so a URL that does not exist yet comes up empty.
        .task(id: preview.path) {
            shareURL = preview.isTruncated ? nil : Self.temporaryCopy(of: preview)
        }
    }

    var canEdit: Bool {
        onSave != nil && preview.kind == .text && preview.isComplete && !preview.isTruncated
            && failure == nil
    }

    var isEditing: Bool { edited != nil }

    var hasUnsavedChanges: Bool {
        guard let edited else { return false }
        return edited != preview.text
    }

    var header: some View {
        HStack(spacing: 11) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ColorPalette.ink)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to the folder")

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ColorPalette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if preview.kind == .text, failure == nil {
                Button { wraps.toggle() } label: {
                    Image(systemName: wraps ? "text.alignleft" : "arrow.left.and.right")
                        .font(.system(size: 15, weight: .semibold))
                        // Accent on the unusual state: wrapping is the default, so tinting it would mark every file ever opened.
                        .foregroundStyle(wraps ? Color.secondary : ColorPalette.accent)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(wraps ? "Scroll long lines" : "Wrap long lines")
            }

            if isEditing {
                Button("Cancel") { edited = nil }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)

                Button {
                    if let edited { onSave?(edited) }
                } label: {
                    Text(isSaving ? "Saving…" : "Save")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(hasUnsavedChanges && !isSaving ? ColorPalette.accent : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(!hasUnsavedChanges || isSaving)
            } else {
                if let shareURL {
                    // The share button keeps its arrow, dimmed with the plan's name, when the plan does not move files, so users can find the feature; tapping opens the plans.
                    PlanLocked(
                        capability: .fileTransfer,
                        title: String(localized: "Download to this device"),
                        diameter: 26
                    ) {
                        ShareLink(item: shareURL) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 30, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Download to this device")
                    }
                }

                if canEdit {
                    Button { edited = preview.text } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit this file")
                }

                if let onRevealPath {
                    Button { onRevealPath(preview.path) } label: {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Put path in command line")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.05))
        .overlay(alignment: .bottom) { hairline }
    }

    @ViewBuilder
    var content: some View {
        if let failure {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(failure)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isEditing {
            editor
        } else if !preview.isComplete {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Reading…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if preview.data.isEmpty && !preview.kind.isDrawn {
            Text("This file is empty.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if preview.kind.isDrawn {
            // There is no first eight megabytes of a JPEG, so a picture cut at the cap is not drawn.
            if preview.isTruncated {
                VStack(spacing: 10) {
                    Image(systemName: "photo")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(
                        """
                        This picture is \
                        \(preview.totalBytes.formatted(.byteCount(style: .file))), which is more \
                        than a preview can carry.
                        """
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                RemoteImageView(
                    data: preview.data,
                    kind: preview.kind,
                    identity: preview.path
                )
            }
        } else {
            reader
        }
    }

    var reader: some View {
        MonospacedTextSurface(text: preview.text, wraps: wraps)
    }

    /// Smart quotes and dashes are system keyboard settings that SwiftUI's `TextEditor` cannot turn off, and a curled quote silently changes a config file.
    var editor: some View {
        VStack(spacing: 0) {
            if let saveFailure {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12, weight: .semibold))
                    Text(saveFailure)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(ColorPalette.caution)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ColorPalette.caution.opacity(0.12))
            }

            MonospacedTextSurface(
                text: edited ?? preview.text,
                onEdit: { edited = $0 },
                wraps: wraps
            )
        }
    }

    var name: String {
        preview.path.split(separator: "/").last.map(String.init) ?? preview.path
    }

    /// On iOS downloading means a temporary copy handed to the share sheet, since an app has no downloads folder. Named after the source file. `nil` when the bytes are not the whole file.
    static func temporaryCopy(of preview: RemoteFilePreview) -> URL? {
        let name = preview.path.split(separator: "/").last.map(String.init) ?? "file"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try preview.data.write(to: url, options: .atomic)
            return url
        } catch {
            panelLog.error("could not write a copy of \(name, privacy: .public) to hand to Files: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    var detail: String {
        let read = preview.data.count.formatted(.byteCount(style: .file))
        guard preview.isTruncated else { return read }
        return String(localized: "Showing the first \(read) of \(preview.totalBytes.formatted(.byteCount(style: .file)))")
    }

    var hairline: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
    }
}
