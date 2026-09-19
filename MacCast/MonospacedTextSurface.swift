import SwiftUI
import UIKit

/// A file's text on screen, wrapping or running off the side, read or written.
///
/// **One view for both modes, and that is the whole point of it.** The panel used to read through a
/// `Text` in two nested scroll views and write through a `TextEditor`, which are two different
/// renderers with two different opinions: the reader never wrapped, because a config, a script and
/// a log are all read by their columns, and the editor always wrapped, because a text field has one
/// axis and no way to have another. So the same file looked like two files depending on whether you
/// had tapped a pencil — and the one thing the two modes should agree about is what the file looks
/// like.
///
/// `UITextView` is the only text view on the platform that can do either, so both modes are this
/// one, one flag apart. That the reader and the editor are now the same object is the point rather
/// than a side effect: they cannot drift again.
///
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
    /// What to show. When ``onEdit`` is absent this is only ever read.
    let text: String
    /// Called with the whole text on every keystroke. Absent for a file that cannot be written,
    /// which is also what makes the surface read-only.
    var onEdit: ((String) -> Void)?
    /// Whether lines wrap to the width of the view. The one thing the two modes share, so that
    /// toggling it means the same thing in both of them.
    var wraps: Bool = true
    var fontSize: CGFloat = 12

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.isSelectable = true
        // Matched to the terminal's own log, which is the other place in this app that shows a
        // file's worth of text: same face, same size, same inset.
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

    /// The two lines that decide whether this wraps.
    ///
    /// Both branches set the container's size and not only the flag, because the flag changes what
    /// the container *asks for* and the size is what it already has: flipping the flag alone leaves
    /// the view laid out to the old width until something else forces a pass.
    ///
    /// Nothing here has to be redone when the view is resized: the wrapped container tracks the
    /// width itself, and the unwrapped one was never interested in it.
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
        /// What the text container was last set to, so that an update which changed nothing about
        /// the wrapping does not re-lay the file out. See ``updateUIView(_:context:)``.
        var appliedWraps: Bool?

        init(onEdit: ((String) -> Void)?) {
            self.onEdit = onEdit
        }

        func textViewDidChange(_ textView: UITextView) {
            onEdit?(textView.text)
        }
    }
}
