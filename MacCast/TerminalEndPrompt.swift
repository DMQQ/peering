import SwiftUI

/// Ending a shell, asked as an alert rather than in a card anchored to the tab.
///
/// **This was a popover, and it was a popover twice. Both times the answer was unreachable.**
///
/// The first failure was horizontal, and it is written down because it is the useful half. The card
/// was anchored to the tab the question is about, and a popover is placed relative to its anchor
/// without ever being pulled back onto the screen: anchored to a tab whose leading edge sits past
/// the middle of the phone, the card ran off the right-hand edge and took the End button with it.
/// The repair was to anchor to a full-width row instead, which puts the card in the same place for
/// one tab as for six, and what carried the "this one" the position used to carry was the shell's
/// name in the question. That reasoning still reads as sound.
///
/// The second failure was vertical and had the same shape. The row being anchored to is a tab strip
/// at the top of the screen, and the card wanted to open above it, so it was cut off at the top
/// edge with its two answers off screen and untappable. Which is the whole of what makes this an
/// alert: **a card that cannot be placed wrongly beats a card in a better place.** The popover's
/// argument was that a question about one tab should be asked where that tab is, and that argument
/// has now cost two broken presentations, in two axes, on the two screens that use it.
///
/// What an alert gives up is the anchor, and it is worth naming what that costs: the question no
/// longer points at the shell it is about. The name in the title is what carries it now, which is
/// the same thing the first repair already fell back on.
extension View {
    /// Attaches the question about ending a shell, whenever `isPresented` is true.
    ///
    /// Attach it to anything in the screen that owns the shell. Where the alert lands no longer
    /// depends on the anchor, which is the entire reason it is an alert.
    func terminalEndPrompt(
        name: String,
        detail: String,
        isPresented: Binding<Bool>,
        onEnd: @escaping () -> Void
    ) -> some View {
        alert("End \(name)?", isPresented: isPresented) {
            // Cancel first, and given the role rather than a colour: Escape maps to it on the
            // simulator and a hardware keyboard, and the role is what keeps the destructive answer
            // from being the one a stray return lands on.
            Button("Keep it", role: .cancel) { }
            Button("End", role: .destructive, action: onEnd)
        } message: {
            Text(detail)
        }
    }
}
