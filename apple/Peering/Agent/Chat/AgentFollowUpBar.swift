import PeeringKit
import SwiftUI

/// What to do next after a turn that changed the project, as buttons over the composer.
struct AgentFollowUpBar: View {
    let suggestions: [AgentFollowUps.Suggestion]
    let choose: (AgentFollowUps.Suggestion) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button { choose(suggestion) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: Self.symbol(suggestion)).font(.system(size: 11, weight: .semibold))
                            Text(Self.title(suggestion)).font(.system(size: 12.5, weight: .medium))
                        }
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .overlay(Capsule().strokeBorder(.white.opacity(0.16)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
        }
        .padding(.top, 6)
    }

    private static func title(_ suggestion: AgentFollowUps.Suggestion) -> LocalizedStringKey {
        switch suggestion {
        case .reviewChanges: "Review changes"
        case .runTests: "Run the tests"
        case .summarizeChanges: "Summarize changes"
        }
    }

    private static func symbol(_ suggestion: AgentFollowUps.Suggestion) -> String {
        switch suggestion {
        case .reviewChanges: "doc.badge.gearshape"
        case .runTests: "checkmark.seal"
        case .summarizeChanges: "text.alignleft"
        }
    }
}
