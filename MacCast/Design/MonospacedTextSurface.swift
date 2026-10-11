import SwiftUI
import UIKit

/// **No wrap is a text container as wide as its longest line.** An unbounded container width
/// leaves the text view's content size at its own width, so the long lines run off screen and
/// nothing scrolls sideways. The container is measured once unbounded, then given that finite
/// width, which is what makes the text view scroll horizontally on its own.
///
/// The view is made on TextKit 1 from the start: asking a TextKit 2 view for its `layoutManager`
/// swaps it over and rebuilds the container with default settings, which silently undid the width
/// set here and left the text wrapping.
/// The text view clamps its own content width to its bounds even when the container is wider, so the width the container asked for is enforced here.
final class SidewaysTextView: UITextView {
    var minimumContentWidth: CGFloat = 0

    override var contentSize: CGSize {
        get { super.contentSize }
        set { super.contentSize = CGSize(width: max(newValue.width, minimumContentWidth), height: newValue.height) }
    }
}

struct MonospacedTextSurface: UIViewRepresentable {
    let text: String
    var onEdit: ((String) -> Void)?
    var wraps: Bool = true
    var fontSize: CGFloat = 12

    func makeUIView(context: Context) -> UITextView {
        let view = SidewaysTextView(usingTextLayoutManager: false)
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
        if view.text != text {
            view.text = text
            if !wraps { Self.applyWrapping(false, to: view) }
        }

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

    fileprivate static func applyWrapping(_ wraps: Bool, to view: UITextView) {
        let container = view.textContainer
        let unbounded = CGFloat.greatestFiniteMagnitude
        if wraps {
            container.widthTracksTextView = true
            container.size = CGSize(width: view.bounds.width, height: unbounded)
            (view as? SidewaysTextView)?.minimumContentWidth = 0
            return
        }
        container.widthTracksTextView = false
        container.size = CGSize(width: unbounded, height: unbounded)
        view.layoutManager.ensureLayout(for: container)
        let longest = view.layoutManager.usedRect(for: container).width
        let visible = view.bounds.width - view.textContainerInset.left - view.textContainerInset.right
        let width = max(longest.rounded(.up), visible)
        container.size = CGSize(width: width, height: unbounded)
        if let sideways = view as? SidewaysTextView {
            sideways.minimumContentWidth = width + view.textContainerInset.left + view.textContainerInset.right
            sideways.contentSize = sideways.contentSize
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
            if appliedWraps == false { MonospacedTextSurface.applyWrapping(false, to: textView) }
        }
    }
}
