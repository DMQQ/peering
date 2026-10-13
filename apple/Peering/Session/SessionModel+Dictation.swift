import Foundation
import PeeringKit
import RemoteCore

extension SessionModel {
    /// Spoken words go where typed ones do: into the field, so a correction can still reach them, and to the Mac.
    func insertDictation(_ spoken: String) {
        let text = DictationText.insertion(after: typedDraft, spoken: spoken)
        guard !text.isEmpty else { return }
        typedDraft += text
        draftSelection = NSRange(location: (typedDraft as NSString).length, length: 0)
        fieldSerial += 1
        lastLocalEdit = MonotonicStamp()
        handleTypedText(text)
    }
}
