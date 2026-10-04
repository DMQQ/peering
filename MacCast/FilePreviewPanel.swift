import RemoteCore
import SwiftUI
import UniformTypeIdentifiers
import MacCastKit
import os

private let panelLog = Logger(subsystem: "pl.dmq.peering", category: "file-browser")

/// A file on another machine, as far as it was read — and, when it can be, edited or looked at.
///
/// **Reading and editing are still two modes, but they are no longer two renderers.** They used to
/// be: the reader never wrapped, because a config, a script and a log are all read by their columns,
/// and the editor always wrapped, because a text field has one axis. The result was the same file
/// looking like two different files depending on whether a pencil had been tapped. Both are now
/// ``MonospacedTextSurface``, one flag apart, with the flag on a toggle in the header — so wrapping
/// is a choice the user makes about the file rather than a consequence of which mode they are in.
///
/// Pictures are the third thing a file can turn out to be, and the panel does not decide that: the
/// kind arrives with the bytes, because the machine that read them is the one that can tell an SVG
/// from a script. See ``RemoteFileKind``.
///
/// The size line says when what is on screen is the beginning of a file rather than the whole of
/// one, and that line is load-bearing rather than informative: **a file that was cut short cannot be
/// edited or downloaded**, because both of those would act on 128 KB as though it were the file.
/// See ``SSHModel/saveFile(_:sessionID:)`` for why the guard is enforced there as well as here.
struct FilePreviewPanel: View {
    let preview: RemoteFilePreview
    let failure: String?
    /// Whether a write is in flight, and the last one that went wrong.
    var isSaving: Bool = false
    var saveFailure: String?

    var onRevealPath: (String) -> Void
    var onClose: () -> Void
    /// Writes the text given back to whichever machine the file is on.
    ///
    /// Absent where the file cannot be written at all, which is now only a shell that has ended:
    /// both browsers can write, and what the `nil` still buys is a pencil that would open an editor
    /// whose Save could never land.
    var onSave: ((String) -> Void)?

    /// The text being edited, or `nil` while the file is only being read.
    @State var edited: String?
    /// A copy of the file on this phone, so it can be handed to Files. See ``temporaryCopy()``.
    @State var shareURL: URL?
    /// Whether lines wrap to the width of the panel. One value for both modes, which is what makes
    /// the reader and the editor agree — see ``MonospacedTextSurface``.
    ///
    /// Starts on, and on is the right default for a panel that is usually opened to see what a file
    /// says. The reason the reader used to be fixed the other way is real, though — a config or a
    /// log is read by its columns — so the choice is here rather than made for the user.
    @State var wraps = true

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(ColorPalette.backdrop)
        // Prepared when the file arrives rather than when the button is pressed: the share sheet
        // reads the file as it opens, so a URL that does not exist yet is a share sheet that comes
        // up empty. The file is at most the preview cap, so this is not a cost worth deferring.
        .task(id: preview.path) {
            shareURL = preview.isTruncated ? nil : Self.temporaryCopy(of: preview)
        }
    }

    /// Whether this file may be changed at all.
    ///
    /// Four ways to be no, and they are different sentences on screen: it is a picture rather than
    /// something with text in it, the file was cut short at the read cap, it is not the whole of
    /// itself yet, or whoever opened this panel has no way to write one back.
    var canEdit: Bool {
        onSave != nil && preview.kind == .text && preview.isComplete && !preview.isTruncated
            && failure == nil
    }

    /// Whether there is anything on screen to edit — an empty file is still a file.
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

            // Present in both modes and doing the same thing in both, which is the point: what it
            // toggles is a property of the file on screen, not of what is being done to it. Hidden
            // for a picture, which has no lines to wrap.
            if preview.kind == .text, failure == nil {
                Button { wraps.toggle() } label: {
                    Image(systemName: wraps ? "text.alignleft" : "arrow.left.and.right")
                        .font(.system(size: 15, weight: .semibold))
                        // Accent on the *unusual* state rather than the on one, unlike the eye in
                        // the browser's bar. Wrapping is the default, so tinting it would leave a
                        // blue glyph in this header for every file ever opened; marking the
                        // exception is what makes the exception visible.
                        .foregroundStyle(wraps ? Color.secondary : ColorPalette.accent)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(wraps ? "Scroll long lines" : "Wrap long lines")
            }

            if isEditing {
                // Words rather than glyphs on this side, unlike the reading side: mid-edit the two
                // choices are the whole question on the screen, and a tick and a cross are two
                // guesses about which does which.
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
                // Absent rather than disabled when the file was cut short: a greyed control invites
                // a tap and explains nothing, and the size line above already says why.
                if let shareURL {
                    // The share button keeps its arrow when the plan does not move files, and it is
                    // drawn even though the copy is already on the phone: what is being sold is
                    // handing it on, and the button the user can see is the whole of how they find
                    // out the app can do it at all. Dimmed, with the plan's name on its corner, the
                    // arrow still says what the tap would do where a badge in its place said
                    // nothing, and tapping it opens the plans.
                    PlanLocked(
                        capability: .fileTransfer,
                        title: "Download to this device",
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
            // A picture that stopped at the cap is not a smaller picture. There is no such thing
            // as the first eight megabytes of a JPEG, so there is nothing to draw and nothing to
            // apologise for by drawing it — said plainly instead, with the size that caused it.
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

    /// The file, read.
    ///
    /// One line of real work, because the wrapping is the surface's business now — but the size,
    /// the face and the inset all still come from here, and they are the same ones ``editor`` gets,
    /// which is what makes the two modes look like the same view.
    var reader: some View {
        MonospacedTextSurface(text: preview.text, wraps: wraps)
    }

    /// The file, being changed.
    ///
    /// The same surface as ``reader``, given a callback instead of nothing. Everything a keyboard
    /// needs to be told is configured there rather than here, and it is worth knowing that a
    /// `TextEditor` would not have let us say all of it anyway: smart quotes and smart dashes are
    /// system keyboard settings SwiftUI gives no way to reach, and a straight quote turned into a
    /// curly one is a silently changed config file.
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

    /// A copy of the file on this phone, so the system's share sheet can take it somewhere.
    ///
    /// **This is what downloading means on iOS**, and it is worth being explicit about because it is
    /// not what it means anywhere else: an app has no downloads folder it may write into, so the
    /// file goes to a temporary location and the sheet decides where it lands — Files, another app,
    /// an email. Named after the file it came from, because the name is the only thing about it that
    /// survives the journey.
    ///
    /// `nil` when the bytes are not the whole file, which the caller checks as well: handing
    /// somebody the first 128 KB of their own file under its real name is worse than not offering it.
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

    /// What was read, and how much of the file that was.
    var detail: String {
        let read = preview.data.count.formatted(.byteCount(style: .file))
        guard preview.isTruncated else { return read }
        return String(localized: "Showing the first \(read) of \(preview.totalBytes.formatted(.byteCount(style: .file)))")
    }

    var hairline: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
    }
}
