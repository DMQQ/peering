import PeeringKit
import SwiftUI

extension AgentEmptyChat {
    /// The person's own prompts, under the built-in suggestions, and the way to add one.
    @ViewBuilder
    var templateRows: some View {
        ForEach(templates.entries) { entry in
            row((symbol: "text.badge.star", text: entry.text, detail: String(localized: "Your prompt")))
                .contextMenu {
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        templates.remove(entry.id)
                        templates.save()
                    }
                }
        }
        Button {
            templateDraft = ""
            addingTemplate = true
        } label: {
            Label("Save your own prompt", systemImage: "plus")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("add-prompt-template")
    }

    func saveTemplate() {
        guard templates.add(templateDraft) else { return }
        templates.save()
    }
}
