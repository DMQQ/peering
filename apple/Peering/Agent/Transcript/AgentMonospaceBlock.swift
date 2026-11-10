import PeeringKit
import RemoteCore
import SwiftUI

struct AgentMonospaceBlock: View {
    let text: String

    @State private var showsAll = false

    private var preview: ToolOutputPreview { ToolOutputPreview(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            block
            if preview.hiddenLines > 0, !showsAll {
                Button {
                    showsAll = true
                } label: {
                    Text("Show \(preview.hiddenLines) more lines")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var block: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(showsAll ? text : preview.shown)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(10)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.05))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.07))
        }
    }
}
