import SwiftUI

/// Ending a shell, asked as an alert rather than a popover anchored to its tab.
///
/// A popover here broke twice: anchored to a tab near the trailing edge it ran off screen
/// horizontally, and anchored above the top tab strip it was cut off vertically with both buttons
/// unreachable. An alert has no anchor to place wrongly. The cost is that the question no longer
/// points at the tab it is about, so the shell's name has to carry that in the title instead.
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
