import RemoteCore
import SwiftUI
import UIKit

struct KeyboardTypingCapture: UIViewRepresentable {
    let model: SessionModel
    var isLarge = false
    @Binding var isFocused: Bool

    func makeUIView(context: Context) -> KeyboardTypingView {
        let view = KeyboardTypingView()
        view.onType = { [weak model] text in model?.handleTypedText(text) }
        view.onDelete = { [weak model] count in
            // One at a time, which is what the Mac hears either way: a correction that replaced a word drops exactly its characters.
            for _ in 0..<count { model?.handleBackspace() }
        }
        view.onReturn = { [weak model] in model?.pressReturn() }
        view.onDraftChange = { [weak model] draft in
            model?.typedDraft = draft
            model?.lastLocalEdit = MonotonicStamp()
        }
        view.restore(model.typedDraft)
        view.appliedFieldSerial = model.fieldSerial
        view.onKey = { [weak model] usage, down, flags in
            model?.handleHardwareKey(usage, down: down, flags: flags)
        }
        return view
    }

    /// A text view has no height SwiftUI will hold it to, so it is computed from content, bounded so it grows the bar and not into the picture.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: KeyboardTypingView,
        context: Context
    ) -> CGSize? {
        let width = proposal.width ?? uiView.intrinsicContentSize.width
        guard width > 0 else { return nil }
        let needed = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        ).height
        return CGSize(
            width: width,
            height: min(
                max(needed, uiView.oneLineHeight),
                uiView.maximumHeight
            )
        )
    }

    func updateUIView(_ view: KeyboardTypingView, context: Context) {
        // Read here, not at construction, because the mode is switchable while the keyboard is up: in keycode mode a correction would arrive as keys for a word nobody typed.
        view.isLarge = isLarge
        let autocorrects = model.keyboardMode == .unicode
        view.autocorrectionType = autocorrects ? .yes : .no
        if view.appliedFieldSerial != model.fieldSerial {
            view.appliedFieldSerial = model.fieldSerial
            view.apply(model.typedDraft, selection: model.draftSelection)
        } else if view.text != model.typedDraft, view.markedTextRange == nil {
            view.restore(model.typedDraft)
        }
        if isFocused, !view.isFirstResponder {
            // A beat, because the binding is set in the same runloop turn the view is installed in, and `becomeFirstResponder` with no window yet is a silent no-op.
            DispatchQueue.main.async { view.becomeFirstResponder() }
        } else if !isFocused, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }
}
