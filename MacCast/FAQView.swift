import SwiftUI

/// Short answers to the questions people need before trusting a remote-desktop app.
struct FAQView: View {
    var body: some View {
        ZStack {
            AppBackdrop()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TabScreenHeader(
                        "FAQ",
                        detail: "Pairing, privacy, and what moves between your devices."
                    )

                    ForEach(Self.sections) { section in
                        sectionView(section)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 36)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func sectionView(_ section: Section) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(section.title)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.question)
                            .font(.subheadline.weight(.semibold))
                        Text(item.answer)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 9)

                    if index < section.items.count - 1 {
                        Divider()
                            .overlay(.white.opacity(0.07))
                    }
                }
            }
        }
        .cardSurface()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct QA: Identifiable {
        var id: String { question }
        let question: String
        let answer: String
    }

    private struct Section: Identifiable {
        var id: String { title }
        let title: String
        let items: [QA]
    }

    private static let sections: [Section] = [
        Section(
            title: "Basics",
            items: [
                QA(
                    question: "Do I need an account?",
                    answer: "No. Peering creates an identity on each device and stores it in that device's Keychain."
                ),
                QA(
                    question: "How do I pair a Mac?",
                    answer: "The two devices have to be able to reach each other once, and somebody has to be at the Mac. On the same local network, choose the Mac from Nearby. If it is somewhere else, open Devices in Peering on the Mac, copy its device ID, and use Pair from another network on the iPhone. Either way, the Mac shows six digits: enter them on the iPhone and continue only if they match."
                ),
                QA(
                    question: "Can I connect away from home?",
                    answer: "Yes. After pairing, Peering can use its relay when the devices are on different networks. You can turn this off under Settings → Remote access."
                )
            ]
        ),
        Section(
            title: "Privacy",
            items: [
                QA(
                    question: "Can the relay see my screen or controls?",
                    answer: "No. It forwards the encrypted connection between your paired devices. It cannot read the video, audio, clipboard text, keystrokes, or pointer input inside it."
                ),
                QA(
                    question: "What does the relay know?",
                    answer: "It receives the Mac's device ID and name, your iPhone's device ID, the protocol version, which plan the app says you are on, and connection usage. A paid connection also sends its relay access key."
                ),
                QA(
                    question: "What does Peering collect?",
                    answer: "The app includes no analytics, advertising, or third-party tracking SDKs."
                )
            ]
        ),
        Section(
            title: "What moves between devices",
            items: [
                QA(
                    question: "Is Mac audio sent?",
                    answer: "Yes, while a session is active. You can mute it from the floating controls."
                ),
                QA(
                    question: "How does clipboard sharing work?",
                    answer: "Text moves only when you pull, push, or choose a saved clipboard item. This iPhone keeps the 12 most recent pulled items until you clear them."
                ),
                QA(
                    question: "Can I transfer files?",
                    answer: "No. Peering transfers the screen, Mac audio, controls, terminal commands, and clipboard text, but not files."
                )
            ]
        ),
        Section(
            title: "Security and troubleshooting",
            items: [
                QA(
                    question: "How are paired devices verified?",
                    answer: "Each device creates its own key and keeps it in Keychain. After you confirm the pairing code, both devices remember the other device's public key."
                ),
                QA(
                    question: "Why is the Mac screen black?",
                    answer: "Check Screen Recording permission for Peering on the Mac, then fully quit and reopen the Mac app."
                ),
                QA(
                    question: "Will a session stay connected in the background?",
                    answer: "Picture in Picture can keep the live view available over other apps. Without it, iOS may suspend Peering after its short background grace period."
                )
            ]
        )
    ]
}

#Preview {
    NavigationStack { FAQView() }
        .preferredColorScheme(.dark)
}
