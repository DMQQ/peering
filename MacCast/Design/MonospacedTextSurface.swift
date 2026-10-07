import SwiftUI
import UIKit

/// **No wrap is a text container with an unbounded width.** `widthTracksTextView` is what makes a
/// text view re-wrap to its own bounds, and turning it off leaves the container asking instead for
/// the width it was given — which, given an unbounded one, is a single line for as long as it needs
/// to be. The text view then scrolls to it on its own, horizontally as well as vertically, so this
/// is not wrapped in SwiftUI scroll views: the scrolling belongs to the view that knows how wide
/// the text is.
///
/// Reading this switches the text view off TextKit 2 and onto TextKit 1, because the container is
/// reached through `textContainer` and that is the compatibility path. It is a supported one, and
/// at a hundred kilobytes of text there is nothing here that would notice the difference.
struct MonospacedTextSurface: UIViewRepresentable {
    let text: String
    var onEdit: ((String) -> Void)?
    var wraps: Bool = true
    var fontSize: CGFloat = 12

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.isSelectable = true
        view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.textColor = UIColor(ColorPalette.ink)
        view.tintColor = UIColor(ColorPalette.accent)
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view.textContainer.lineFragmentPadding = 0
        view.keyboardAppearance = .dark
        view.keyboardDismissMode = .interactive
        // None of these are preferences. This is a config file or a script, and a keyboard that
        // capitalises the first word of a line, straightens a quote or offers to complete a word
        // has changed what the file means before anybody saved it.
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.keyboardType = .asciiCapable
        view.text = text
        view.isEditable = onEdit != nil
        Self.applyWrapping(wraps, to: view)
        context.coordinator.appliedWraps = wraps
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.onEdit = onEdit

        // Guarded, and the guard is load-bearing rather than an optimisation: assigning the text
        // sends the selection back to the start, so an unguarded assignment on every keystroke
        // would put the caret at the top of the file after every character typed. The two agree
        // while typing — the coordinator's callback fed this exact string back — so the guard is
        // what keeps typing from being undone by the redraw it caused.
        if view.text != text { view.text = text }

        let editable = onEdit != nil
        if view.isEditable != editable { view.isEditable = editable }

        // Only when it has actually changed, and that is not an optimisation either. This runs on
        // every keystroke, because every keystroke changes the text this view is being asked to
        // show; touching the container re-lays the whole file out, which mid-sentence is a caret
        // that jumps and a view that stutters. Which one it is tracks what was last applied rather
        // than what is asked for, so the view and this flag cannot disagree about the layout.
        if context.coordinator.appliedWraps != wraps {
            context.coordinator.appliedWraps = wraps
            Self.applyWrapping(wraps, to: view)
        }
    }

    /// Both branches set the container's size and not only the flag, because the flag changes what
    /// the container *asks for* and the size is what it already has: flipping the flag alone leaves
    /// the view laid out to the old width until something else forces a pass.
    private static func applyWrapping(_ wraps: Bool, to view: UITextView) {
        let container = view.textContainer
        let unbounded = CGFloat.greatestFiniteMagnitude
        if wraps {
            container.widthTracksTextView = true
            container.size = CGSize(width: view.bounds.width, height: unbounded)
        } else {
            container.widthTracksTextView = false
            container.size = CGSize(width: unbounded, height: unbounded)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onEdit: onEdit) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onEdit: ((String) -> Void)?
        var appliedWraps: Bool?

        init(onEdit: ((String) -> Void)?) {
            self.onEdit = onEdit
        }

        func textViewDidChange(_ textView: UITextView) {
            onEdit?(textView.text)
        }
    }
}
