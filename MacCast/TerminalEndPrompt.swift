import SwiftUI

/// An alert, not a popover: an anchored popover ran off screen at the trailing edge and was cut off above the top tab strip.
extension View {
    func terminalEndPrompt(
        name: String,
        detail: String,
        isPresented: Binding<Bool>,
        onEnd: @escaping () -> Void
    ) -> some View {
        alert("End \(name)?", isPresented: isPresented) {
            // Cancel first, with the role: Escape maps to it, and a stray return must not land on the destructive answer.
            Button("Keep it", role: .cancel) { }
            Button("End", role: .destructive, action: onEnd)
        } message: {
            Text(detail)
        }
    }
}
