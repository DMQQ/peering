import SwiftUI

/// Ending a shell, asked about at the top of the screen the shell is on.
///
/// Not a `confirmationDialog`, which is what this was and is the wrong shape for the question. On
/// iPhone that presents as an action sheet pinned to the bottom edge, so a cross tapped on a tab
/// at the top of the screen raises a question at the bottom of it — with the tab still visible
/// above and nothing joining the two. An action sheet is right for "what do you want to do with
/// this photo"; this is a question about one specific tab, and it should be asked where that tab
/// is.
///
/// A popover with `attachmentAnchor: .rect(.bounds)` does exactly that: it opens against the
/// bounds of whatever it is attached to, and `.presentationCompactAdaptation(.popover)` is what
/// stops iPhone turning it back into a sheet.
struct TerminalEndPrompt: View {
    let name: String
    /// What stops, in this terminal's own terms — a shell on the Mac, or one on a server.
    let detail: String
    let onEnd: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("End \(name)?")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ColorPalette.ink)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("Keep it", role: .cancel, action: onCancel)
                    .buttonStyle(.bordered)

                Spacer(minLength: 0)

                Button("End", role: .destructive, action: onEnd)
                    .buttonStyle(.borderedProminent)
                    .tint(ColorPalette.danger)
                    .foregroundStyle(.white)
            }
            .padding(.top, 2)
        }
        // Wide enough that the sentence is two lines rather than five, narrow enough to sit under
        // a tab without running off the screen.
        .frame(width: 280)
        .padding(14)
        .preferredColorScheme(.dark)
    }
}

extension View {
    /// Attaches ``TerminalEndPrompt``, anchored to the bounds of whatever it is attached to.
    ///
    /// **Attach it to a full-width row, not to the thing the question is about.** That is not what
    /// this started as, and the difference is a defect rather than a nicety. A popover is placed
    /// relative to its anchor and is *not* pulled back onto the screen: anchored to a tab whose
    /// leading edge is past the middle of the phone, the card runs off the right-hand edge and
    /// takes the End button with it, leaving a question with one visible answer and one that
    /// nobody can reach. Three guesses at the cause were tested in the simulator and all three
    /// were wrong — it is not the horizontal scroller the tabs live in (taking the scroller out
    /// changed nothing), it is not the width of the card (a narrow one clips as readily), and it
    /// is not the arrow edge. It is where the anchor sits on the screen, and no modifier fixes
    /// that from the anchor's side.
    ///
    /// A row that spans the width and sits at the top puts the card in the same place for one tab
    /// as for six. What carries the "this one" that the position used to is the name in the
    /// question. Both call sites are tab strips — ``TerminalPanel`` and ``SSHTerminalScreen`` —
    /// and ``SSHTab`` gets away with attaching it to a row because those rows are full width and
    /// start at the left edge.
    func terminalEndPrompt(
        name: String,
        detail: String,
        isPresented: Binding<Bool>,
        onEnd: @escaping () -> Void
    ) -> some View {
        popover(isPresented: isPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            TerminalEndPrompt(
                name: name,
                detail: detail,
                onEnd: onEnd,
                onCancel: { isPresented.wrappedValue = false }
            )
            .presentationCompactAdaptation(.popover)
        }
    }
}
