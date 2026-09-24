import MessageUI
import SwiftUI

/// Apple's own compose sheet, wrapped for the one screen that needs a real attachment.
///
/// `mailto:` has no way to carry one — there is no attachment parameter in the scheme, on any mail
/// app — so a diagnostics file has to go through `MFMailComposeViewController` instead. That still
/// opens as a draft the user reviews and can delete from before they choose Send, which is the same
/// promise the plain `mailto:` link made: nothing leaves this device without that tap.
struct MailComposer: UIViewControllerRepresentable {
    let recipient: String
    let subject: String
    let body: String
    let attachment: (data: Data, mimeType: String, fileName: String)?
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients([recipient])
        controller.setSubject(subject)
        controller.setMessageBody(body, isHTML: false)
        if let attachment {
            controller.addAttachmentData(attachment.data, mimeType: attachment.mimeType, fileName: attachment.fileName)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            onFinish()
        }
    }
}
