import SwiftUI

/// Short answers to the questions people need before trusting a remote-desktop app.
///
/// **Every answer is behind a tap**, and that is a change worth explaining rather than a taste.
/// The list used to be open, which meant the first thing a reader met was a screen of prose with
/// no shape to it: thirty answers run together is a page nobody finishes, and the one question
/// somebody actually had was somewhere in the middle of it. Closed, the same list is an index:
/// every question is visible at once and the reader picks the one they came for. Nothing is
/// hidden by this; the questions *are* the content until one of them is asked.
///
/// **What is written here is checked against the app rather than against the plan for it.** A FAQ
/// is the one screen where a claim and a feature are compared directly, and a promise kept here
/// about a control that does not exist is worse than the feature being missing, because the reader
/// spends their time looking for a button. So "Known gaps" is a section rather than an omission,
/// and it is written to be read by somebody deciding whether to pay.
struct FAQView: View {
    /// The questions that are open, by their text.
    ///
    /// More than one at a time, deliberately: this is a reference page, and somebody comparing
    /// two answers should not have to hold the first one in their head while they open the second.
    @State private var opened: Set<String> = []

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
                    row(item, isLast: index == section.items.count - 1)
                }
            }
        }
        .cardSurface()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One question, and its answer when it is open.
    ///
    /// The chevron turns rather than being swapped for another glyph, because a rotation is the
    /// same mark in two positions and reads as one control changing; two different symbols read as
    /// two controls, one of which appeared where the other was.
    private func row(_ item: QA, isLast: Bool) -> some View {
        let isOpen = opened.contains(item.id)

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.tap) {
                    if isOpen { opened.remove(item.id) } else { opened.insert(item.id) }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(item.question)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ColorPalette.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.vertical, 11)
                // The whole row is the target, not the two words in it. A question wraps on a
                // narrow phone, and a tap on the second line of one has to do what a tap on the
                // first line does.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.question)
            .accessibilityHint(isOpen ? "Hide the answer" : "Show the answer")

            if isOpen {
                Text(item.answer)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }

            if !isLast {
                Divider()
                    .overlay(.white.opacity(0.07))
            }
        }
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
            title: "Getting started",
            items: [
                QA(
                    question: "Do I need an account?",
                    answer: "No. Each device creates its own identity and keeps the key in that device's Keychain. There is no sign-up, no email, and nothing about you stored on a server."
                ),
                QA(
                    question: "How do I pair a Mac?",
                    answer: "The two devices have to be able to reach each other once, and somebody has to be at the Mac. On the same network, choose the Mac from Nearby. If it is somewhere else, open Devices in Peering on the Mac, copy its device ID, and use Pair from another network on the iPhone. Either way the Mac shows six digits: enter them on the iPhone and continue only if they match. You pair once; after that the devices recognise each other and reconnect on their own."
                ),
                QA(
                    question: "What does the Mac need?",
                    answer: "The Peering app for macOS, running, with two permissions allowed: Screen Recording, which is what lets it capture the screen, and Accessibility, which is what lets it move the pointer and type. Both live in System Settings → Privacy & Security, and the Mac app shows their state with a button to open the right pane."
                ),
                QA(
                    question: "Can I connect away from home?",
                    answer: "Yes, and it tries two ways in order. First the two devices look for a path straight between themselves; if the networks will not allow one, Peering's relay carries the session instead. The session screen shows which is in use as LAN, RELAY, or DIRECT·P2P. You can turn the relay off entirely under Settings → Remote access, which leaves connections on your own network only."
                ),
                QA(
                    question: "Does my Mac have to be awake?",
                    answer: "It has to be on to hold a session. A Mac you have paired with can be woken from its row in the Connect tab, which sends a wake-up packet, but that packet goes out on the local network, so it works when you are at home and not when you are away. A sleeping Mac off your network cannot be woken from here."
                ),
                QA(
                    question: "How many Macs can I use?",
                    answer: "As many as you pair. They all appear in the Connect tab with their own menu, and one session runs at a time. Starting another ends the first."
                ),
                QA(
                    question: "Can two phones use the same Mac?",
                    answer: "Yes. The Mac accepts more than one connected device and can disconnect them one at a time. The picture itself is sent to one device at a time, so a second phone watching the same Mac is not getting a second stream."
                ),
            ]
        ),

        Section(
            title: "Privacy",
            items: [
                QA(
                    question: "Can the relay see my screen or controls?",
                    answer: "No. It forwards an encrypted connection it holds no key for. The video, the audio, clipboard text, keystrokes and pointer input are all inside that connection, and the relay can read none of them."
                ),
                QA(
                    question: "What does the relay know?",
                    answer: "The Mac's device ID and name, your iPhone's device ID, the protocol version, which plan the app says you are on, and how much you have used it. A paid connection also sends its relay access key. It does not see inside the session, and it does not keep a record of what was on your screen."
                ),
                QA(
                    question: "Does the video go through your servers?",
                    answer: "Only when it has to. When the two devices can reach each other directly, the picture takes that path and only the control connection stays on the relay. When they cannot, which is common on restrictive networks, the relay carries the picture too. This is not a setting; the app tries the direct path and falls back on its own."
                ),
                QA(
                    question: "Can I stop someone at the Mac from watching?",
                    answer: "Yes. Turn on Darken the Mac's displays during a session and the Mac's own screens go dark while capture keeps running, so you can work without the room reading over your shoulder. They come back when you turn it off or end the session."
                ),
                QA(
                    question: "Can I lock the app, or one server?",
                    answer: "Both. Face ID for the whole app is under Settings, and asks each time the app comes back. Each saved SSH server can separately require Face ID or a six-digit passcode of your own before it will open."
                ),
                QA(
                    question: "What does Peering collect?",
                    answer: "Nothing. There is no analytics, no advertising, and no third-party tracking SDK in the app. The diagnostics you can copy from Settings are assembled on the device and only go anywhere if you send them yourself."
                ),
            ]
        ),

        Section(
            title: "What moves between devices",
            items: [
                QA(
                    question: "Is Mac audio sent?",
                    answer: "The Mac's audio is captured and sent, but the app has no control to unmute it yet, so a session is silent today. There is no setting for it in this version."
                ),
                QA(
                    question: "How does clipboard sharing work?",
                    answer: "Text moves only when you ask it to: pull the Mac's clipboard, push this phone's, or pick something you pulled earlier. The iPhone keeps the 12 most recent pulled items until you clear them. Nothing is copied in the background."
                ),
                QA(
                    question: "Can I transfer files?",
                    answer: "Yes, from the file browser inside a terminal. You can read a file, download it to the phone, edit a text file and save it back, and send a file from the phone into the folder you are looking at. The limits are worth knowing: text files are read up to 128 KB, and a longer one can be read but not edited or downloaded, because saving would replace the whole file with only the part you were shown. Binary files are not shown. Uploads are capped at 64 MB. The browser cannot yet delete, rename, or create folders."
                ),
                QA(
                    question: "Can I open a terminal?",
                    answer: "Yes, two kinds. One is a shell on the Mac itself, opened inside the session, with tabs you can rename and a key row for the control keys a phone keyboard cannot send. The other is a saved SSH server, which connects straight from the phone and does not involve the Mac at all. Both file browsers can browse, preview, download, edit and upload."
                ),
                QA(
                    question: "Can I reach my server, or only my Mac?",
                    answer: "Any SSH server you add under Servers. Sign-in is by password, stored in the Keychain if you ask for it to be remembered, and the first time you connect the server's key fingerprint is shown for you to confirm. That server's files are reachable through the same browser as the Mac's."
                ),
            ]
        ),

        Section(
            title: "Plans",
            items: [
                QA(
                    question: "What is free?",
                    answer: "Connecting over your own network, with no limit and no time counted. The relay is the part that reaches a Mac on another network, and free includes half an hour of it in each rolling 24 hours."
                ),
                QA(
                    question: "What happens when my relay time runs out?",
                    answer: "The relay stops carrying sessions until the window rolls over, and the Sessions tab shows the meter counting down. Connections on your own network keep working the whole time. Relay raises the allowance to three hours a day, and Relay Plus and Pro remove the limit."
                ),
                QA(
                    question: "Why does the app ask me to subscribe?",
                    answer: "It asks after your first session, and again if your relay allowance is nearly gone. Both are a single prompt with a way to dismiss it; nothing is charged without you confirming it through the App Store."
                ),
            ]
        ),

        Section(
            title: "Security and troubleshooting",
            items: [
                QA(
                    question: "How are paired devices verified?",
                    answer: "Each device creates its own key and keeps it in the Keychain. When you confirm the six-digit code, both devices record the other's public key and refuse to connect to anything else claiming that identity. The relay cannot substitute itself for either end."
                ),
                QA(
                    question: "Why is the Mac screen black?",
                    answer: "Almost always Screen Recording. Check System Settings → Privacy & Security → Screen Recording on the Mac, then fully quit Peering on the Mac and open it again. The permission is only picked up at launch."
                ),
                QA(
                    question: "The picture looks soft. Can I change it?",
                    answer: "Yes. The speedometer chip on the session screen sets Auto, Low, Medium or High. Auto follows what the connection can carry, stepping down when latency rises and back up when it settles, so a weak link goes soft rather than stalling."
                ),
                QA(
                    question: "Will a session stay connected in the background?",
                    answer: "Picture in Picture keeps the live view over other apps, and the Live Activity keeps the session's state on the Lock Screen. Without those, iOS suspends the app after a short grace period and the session drops. Peering then retries a few times with a growing gap, and picks the session back up if you return."
                ),
                QA(
                    question: "Why can't I edit this file?",
                    answer: "Three reasons, and the panel says which. The file was longer than the read limit, so only its beginning is on screen and saving would throw the rest away. Or it is not text in UTF-8, which this editor cannot represent. Or the shell it was opened from has ended, in which case there is nothing left to save through."
                ),
            ]
        ),

        Section(
            title: "Known gaps",
            items: [
                QA(
                    question: "What can't Peering do yet?",
                    answer: "A list rather than a promise. Mac audio is captured but cannot be unmuted, so sessions are silent. The file browser cannot delete, rename, or make folders. There is no dictation button. SSH sign-in is password only: no key files, and no port forwarding. A Mac asleep and off your network cannot be woken. There is no virtual display, so a Mac with its lid shut and no screen attached has nothing to show."
                ),
                QA(
                    question: "Is any of that coming?",
                    answer: "Some of it. Nothing on that list is a design decision we are defending; each is simply not built. The FAQ will say so when it changes, because a list like this is only worth reading if it is kept."
                ),
            ]
        ),
    ]
}

#Preview {
    NavigationStack { FAQView() }
        .preferredColorScheme(.dark)
}
