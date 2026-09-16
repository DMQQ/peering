import SwiftUI

/// How it works, what it sends, and what it never sends.
///
/// Collapsed rather than laid out flat, because the honest answer to "is this safe" is long and
/// the person reading it usually arrived with one question. A page that opens on a wall of text
/// asks someone who came for one answer to read six; this way the questions *are* the page and
/// the answers are one tap behind them.
///
/// Everything here is checkable against the code, and that is the point: a claim in this file
/// that the app does not honour is worse than no claim at all, because this is the screen a
/// suspicious user reads to decide whether to trust it with their desktop.
///
/// **Two rules for editing this file.** No claim that is not literally true of the code — the
/// relay's own README says it best, "that property is the product". And no quiet omission: the
/// relay is a server, the Mac does hold a connection open to it by default, and both of those
/// are stated here rather than left for the user to discover.
///
/// The three things a reader most often assumes are all false and are all answered below: the
/// Mac's audio is never sent, the clipboard is never synced, and no file ever moves between the
/// two devices.
struct FAQView: View {
    /// The questions currently open, by id.
    ///
    /// Several at once rather than one at a time. These are not tabs; a reader comparing "what
    /// the relay can see" against "what is never sent" should not have to close one to read the
    /// other.
    @State private var open: Set<String> = []

    var body: some View {
        ZStack {
            ColorPalette.backdrop.ignoresSafeArea()
            light

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(Self.sections) { section in
                        sectionView(section)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 36)
            }
        }
        .navigationTitle("How Peering works")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sectionView(_ section: Section) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(section.title)
            VStack(spacing: 5) {
                ForEach(section.items) { item in
                    row(item)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ item: QA) -> some View {
        let isOpen = open.contains(item.id)

        return Button {
            withAnimation(Motion.settle) {
                if isOpen {
                    open.remove(item.id)
                } else {
                    open.insert(item.id)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(item.question)
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)

                    // Points down when there is something to open, up when there is something to
                    // close. The rotation is the whole of the feedback that the row is a control
                    // rather than a heading, so it is on `Motion.tap` — the app's curve for a
                    // control changing state — and not on the spring the row itself opens with.
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                        .animation(Motion.tap, value: isOpen)
                }

                if isOpen {
                    Text(item.answer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        // Opacity only. A move or a scale would make the rows below jump as this
                        // one grows, which reads as the page rearranging itself under the finger
                        // that just tapped.
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .rowSurface()
            .contentShape(Rectangle())
        }
        .buttonStyle(RailButtonStyle(scale: 0.98))
        .accessibilityHint(isOpen ? "Hides the answer" : "Shows the answer")
    }

    /// The same single soft light from the top that the host picker uses. See
    /// ``HostPickerView`` — the backdrop alone reads as a hole rather than a surface.
    private var light: some View {
        RadialGradient(
            colors: [.white.opacity(0.07), .clear],
            center: .top,
            startRadius: 0,
            endRadius: 460
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - The questions

    private struct QA: Identifiable {
        /// The question is the id. They are unique by construction and it saves a parallel set of
        /// hand-written keys that could drift from the text they name.
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
            title: "The short version",
            items: [
                QA(
                    question: "Is there an account?",
                    answer: "No. Nothing to sign up for, nothing to log into, and no service holding your Mac's details. The two devices recognise each other directly."
                ),
                QA(
                    question: "Can anyone else see my screen?",
                    answer: "No. Even when your Mac is reached through the relay, what travels is a TLS session belonging to your two devices. The relay copies it without being able to open it."
                ),
                QA(
                    question: "What do you collect?",
                    answer: "Nothing. No analytics, no crash reporting, no telemetry, no advertising identifier. The app has no third-party SDKs in it at all."
                )
            ]
        ),
        Section(
            title: "How the two devices find each other",
            items: [
                QA(
                    question: "Can I pair with a Mac remotely the first time?",
                    answer: "No. For the first connection, the iPhone and Mac must be on the same local network so you can compare the pairing code shown on both devices. Once they are paired, they recognise each other by their pinned keys and can reconnect through the relay from different networks."
                ),
                QA(
                    question: "On the same network.",
                    answer: "Your Mac announces itself with Bonjour, the same mechanism AirDrop and network printers use. Your phone finds it, and the connection is made directly between the two of them. It never leaves the network."
                ),
                QA(
                    question: "When they are not.",
                    answer: "Both ends connect outward to a relay at peering.dmqq.dev, which introduces them and then copies bytes between them. It does not terminate the encryption and it is never told the key."
                ),
                QA(
                    question: "Can I turn the relay off?",
                    answer: "Yes. Settings, then Privacy, then Allow the relay, while a session is running. With it off the app only ever connects over the network you are both on, and a Mac somewhere else becomes unreachable rather than relayed."
                ),
                QA(
                    question: "What if the relay is unavailable?",
                    answer: "Peering labels a failed remote connection separately and does not blame the Mac. If the relay is reachable but your Mac is not connected to it, the app says the Mac is unavailable instead. A nearby Mac can still be reached directly from the same local network."
                )
            ]
        ),
        Section(
            title: "What the relay can see",
            items: [
                QA(
                    question: "It cannot see your screen.",
                    answer: "Video is sealed with a key the two devices exchanged over their own encrypted session. The relay was never told it, cannot derive it, and cannot alter what it forwards without the two ends noticing."
                ),
                QA(
                    question: "It cannot see your keystrokes, or anything else you do.",
                    answer: "Input travels inside the same encrypted session as the picture."
                ),
                QA(
                    question: "It can see that a connection happened.",
                    answer: "Your Mac's device ID and name, your phone's, the protocol version, and when and how much you connected. Those are the fields in the relay's signalling messages, and they are the whole of it. They are what introduces two devices that cannot see each other."
                ),
                QA(
                    question: "Could someone else ask the relay to reach my Mac?",
                    answer: "They can ask, and they will not get in. Anyone who learns your Mac's device ID can open a pipe to it, which is deliberate: the relay is not what grants access, the encryption handshake and the pinned key are. A stranger who knows the ID gets a pipe, and then fails to get through it."
                )
            ]
        ),
        Section(
            title: "What is never sent",
            items: [
                QA(
                    question: "Sound.",
                    answer: "The Mac's audio is not captured and not transmitted. Nothing plays through your phone."
                ),
                QA(
                    question: "Your clipboard.",
                    answer: "Nothing is copied between the two devices in either direction."
                ),
                QA(
                    question: "Files.",
                    answer: "There is no file transfer of any kind."
                ),
                QA(
                    question: "Your camera and microphone.",
                    answer: "Neither is captured on the Mac. The phone's camera does one thing: scanning the pairing code on your Mac's screen, if you choose to scan rather than type."
                )
            ]
        ),
        Section(
            title: "How the encryption works",
            items: [
                QA(
                    question: "TLS 1.3, with both ends authenticated.",
                    answer: "Not just the Mac proving who it is. Your phone presents its own certificate too, so neither end can be impersonated to the other."
                ),
                QA(
                    question: "Each device makes its own identity.",
                    answer: "A P-256 key generated on the device itself and kept in its keychain. There is no certificate authority in the middle, and nothing to renew."
                ),
                QA(
                    question: "Pairing is a code you compare by eye.",
                    answer: "Your Mac shows six digits and your phone shows the same six. If they match, the two devices pin each other's key and every later connection is silent. The digits are derived from the handshake itself and committed to in advance, so neither side can steer them."
                ),
                QA(
                    question: "The key is what is stored, not the address.",
                    answer: "What gets pinned is the public key. Your Mac can change networks, and your phone can change networks, without either of them having to be re-paired."
                )
            ]
        ),
        // Volunteered because the alternative is a user noticing the battery drain and having no
        // way to find out why. It is a real cost of a real feature, and naming it is cheaper than
        // being caught not naming it.
        Section(
            title: "Two things worth knowing",
            items: [
                QA(
                    question: "A session keeps the app awake.",
                    answer: "While a session is running and the app is in the background, the app holds a silent audio session open so iOS does not suspend it and drop your connection. That keeps the radio and the processor awake for as long as the session lasts, and it costs battery."
                ),
                QA(
                    question: "The Mac side needs Screen Recording.",
                    answer: "The Mac app cannot capture its screen without that permission, and macOS gives it no way to ask on your behalf. macOS also does not tell an app when it has been refused. The picture simply arrives black. If your Mac's screen shows up blank, that permission is the first thing to check."
                )
            ]
        )
    ]
}

#Preview {
    NavigationStack { FAQView() }
        .preferredColorScheme(.dark)
}
