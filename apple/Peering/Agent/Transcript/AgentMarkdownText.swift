import PeeringKit
import RemoteCore
import SwiftUI

struct AgentMarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(AgentMarkdown.split(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let paragraph):
                    Self.inline(paragraph)
                        .font(.system(size: 15.5))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                case .heading(let level, let heading):
                    Self.inline(heading)
                        .font(.system(size: level <= 2 ? 17 : 15.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.top, 2)
                        .textSelection(.enabled)
                case .code(let code):
                    AgentMonospaceBlock(text: code)
                case .bullets(let bullets):
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(bullets.enumerated()), id: \.offset) { _, bullet in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text("•")
                                    .font(.system(size: 15.5))
                                    .foregroundStyle(.white.opacity(0.5))
                                Self.inline(bullet)
                                    .font(.system(size: 15.5))
                                    .foregroundStyle(.white.opacity(0.95))
                                    .lineSpacing(3)
                            }
                        }
                    }
                    .padding(.leading, 2)
                case .table(let table):
                    AgentMarkdownTableView(table: table)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Raw text when markdown does not parse: a half-typed `**` mid-stream must not make the line vanish.
    static func inline(_ string: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(string)
    }
}
