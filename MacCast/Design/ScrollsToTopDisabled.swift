import SwiftUI
import UIKit

extension View {
    /// Turns off the system's tap-the-status-bar jump to the top for the scroll view this sits in. A chat's toolbar buttons sit right under the status bar, and a tap on a button's upper edge was read as that gesture and threw the conversation to its start.
    func scrollsToTopDisabled() -> some View {
        background(ScrollsToTopSwitch())
    }
}

private struct ScrollsToTopSwitch: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        // The scroll view is an ancestor only once the view is in a window.
        DispatchQueue.main.async {
            var ancestor = view.superview
            while let current = ancestor, !(current is UIScrollView) { ancestor = current.superview }
            (ancestor as? UIScrollView)?.scrollsToTop = false
        }
    }
}
