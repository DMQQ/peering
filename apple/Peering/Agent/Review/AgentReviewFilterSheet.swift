import PeeringKit
import RemoteCore
import SwiftUI

/// What the To review list leaves out. Changes apply at once and are remembered.
struct AgentReviewFilterSheet: View {
    @Binding var filter: AgentReviewFilter
    /// Only the Changes screen reads a chat's transcript, so only it can offer the agent-edited rule.
    var offersAgentRule = false

    @Environment(\.dismiss) private var dismiss
    @State private var pattern = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Controls.card(String(localized: "Show")) {
                        Controls.toggle(String(localized: "Hide hidden folders"), systemImage: "eye.slash", isOn: $filter.hidesHiddenFolders)
                        Controls.divider
                        Controls.toggle(String(localized: "Untracked files"), systemImage: "doc.badge.plus", isOn: $filter.showsUntracked)
                        if offersAgentRule {
                            Controls.divider
                            Controls.toggle(String(localized: "Only files this agent edited"), systemImage: "sparkle", isOn: $filter.onlyAgentEdited)
                        }
                    }
                    kindsCard
                    patternsCard
                    Text("These filters are shared with To review and every chat's Changes.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .background(ColorPalette.backdrop)
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(ColorPalette.backdrop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if !(offersAgentRule ? filter.isDefault : filter.isDefaultIgnoringAgentRule) {
                    ToolbarItem(placement: .cancellationAction) { Button("Reset") { filter = AgentReviewFilter() } }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    private var kindsCard: some View {
        Controls.card(String(localized: "Kinds of change")) {
            HStack(spacing: 8) {
                chip("Modified", .modified)
                chip("Added", .added)
                chip("Deleted", .deleted)
                chip("Untracked", .untracked)
            }
        }
    }

    private var patternsCard: some View {
        Controls.card(
            String(localized: "Hide paths containing"),
            footer: String(localized: "For example .skills or node_modules. Matching ignores case.")
        ) {
            HStack(spacing: 8) {
                InputCapsule {
                    TextField("Part of a path", text: $pattern)
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(addPattern)
                }
                InputSendButton(symbol: "plus", isEnabled: !pattern.trimmingCharacters(in: .whitespaces).isEmpty, label: "Add pattern", action: addPattern)
            }
            ForEach(filter.hiddenPatterns, id: \.self) { entry in
                HStack {
                    Text(verbatim: entry).font(.system(size: 13, design: .monospaced)).foregroundStyle(ColorPalette.ink)
                    Spacer(minLength: 8)
                    Button { filter.removePattern(entry) } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                            .frame(width: 32, height: 32).contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text("Remove pattern"))
                }
            }
        }
    }

    private func chip(_ title: LocalizedStringKey, _ kind: AgentChangeKind) -> some View {
        let isOn = filter.kinds.contains(kind)
        return Button { filter.toggle(kind) } label: {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(isOn ? ColorPalette.onInk : .white.opacity(0.8))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(isOn ? ColorPalette.ink : .clear, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(isOn ? 0 : 0.16)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func addPattern() {
        filter.addPattern(pattern)
        pattern = ""
    }
}
