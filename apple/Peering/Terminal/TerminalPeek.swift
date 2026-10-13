import SwiftUI

/// What a long press on a terminal shows without opening it: the end of its screen, not answerable.
struct TerminalPeek: View {
    let terminal: TerminalCardDigest

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: terminal.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ColorPalette.ink)
                    .lineLimit(1)
                if let folder = terminal.folder {
                    Text(verbatim: folder)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            VStack(alignment: .leading, spacing: 3) {
                if terminal.peekLines.isEmpty {
                    Text("Nothing on screen")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                }
                ForEach(Array(terminal.peekLines.enumerated()), id: \.offset) { offset, line in
                    Text(verbatim: line)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(offset == terminal.peekLines.count - 1 ? 0.9 : 0.55))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(14)
        }
        .frame(width: 360, height: 420)
        .background(ColorPalette.backdrop)
        .preferredColorScheme(.dark)
    }
}
