import MacCastKit
import RemoteCore
import SwiftUI

extension FilePreviewPanel {
    /// The actions of ``header`` for a page on a navigation stack: reading controls on the top bar, file actions on the bottom one.
    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if isEditing {
                // Up here rather than at the bottom, which the keyboard covers while editing.
                Button("Cancel") { edited = nil }
                Button(isSaving ? "Saving…" : "Save") {
                    if let edited { onSave?(edited) }
                }
                .fontWeight(.semibold)
                .disabled(!hasUnsavedChanges || isSaving)
            } else if preview.kind == .text, failure == nil {
                Button { wraps.toggle() } label: {
                    Image(systemName: wraps ? "text.alignleft" : "arrow.left.and.right")
                }
                .accessibilityLabel(wraps ? "Scroll long lines" : "Wrap long lines")
            }
        }

        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("Done") {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }

        ToolbarItem(placement: .bottomBar) {
            if !isEditing, let shareURL {
                // Dimmed with the plan's name when the plan does not move files, so users can find the feature; tapping opens the plans.
                PlanLocked(
                    capability: .fileTransfer,
                    title: String(localized: "Download to this device"),
                    diameter: 26
                ) {
                    ShareLink(item: shareURL) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Download to this device")
                }
            }
        }

        ToolbarItem(placement: .status) {
            Text(statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 14)
                .frame(minWidth: 210)
        }

        ToolbarItem(placement: .bottomBar) {
            if canEdit, !isEditing {
                Button { edited = preview.text } label: { Image(systemName: "pencil") }
                    .accessibilityLabel("Edit this file")
            }
        }
    }

    /// The size, and when it last changed when the folder listing knew.
    private var statusLine: String {
        guard let modified else { return detail }
        return detail + " · " + modified.formatted(.relative(presentation: .named))
    }
}
