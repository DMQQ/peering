import SwiftUI

/// One thing the app does, and the plan it needs if it needs one.
///
/// `plan` is `nil` for everything the free plan includes, which is most of the app. Where it is
/// set, the row draws a badge and the plan named there is what the paywall's own card for that
/// tier claims, in the same words. The two screens are one tap apart, so a feature that is free
/// here and paid there is not a difference of opinion, it is a page contradicting itself.
///
/// **The badge is a statement about the product, not about the code.** Nothing on this screen is
/// enforced: the only thing the app meters today is relay time, and a user who never subscribes
/// can still open a terminal. Filling this in is the first half of gating them and not the whole
/// of it, and the copy below is written so that it stays true until the second half lands.
struct PlanFeature: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let detail: String
    var plan: StoreManager.Tier?
}

struct PlanFeatureGroup: Identifiable {
    let id = UUID()
    let title: String
    let features: [PlanFeature]
}

/// Everything the app does, in one place, one tap from the subscription sheet.
///
/// A paywall is a comparison, and a comparison is only as honest as what it leaves out. The cards
/// answer "which of these is worth it" in three lines each, which is the right length for a
/// decision and the wrong length for an inventory, so the sheet carries a way to see the whole
/// list rather than making its case by omission.
///
/// It is also the answer to a question people actually ask before subscribing: *what am I paying
/// for, exactly*. The list is checkable against the app, one line per claim, which is the same
/// rule the FAQ and the landing page follow.
struct PlanFeaturesView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        TabScreenHeader(
                            "Everything included",
                            detail: "Most of the app is in every plan, the free one included. A row wearing a plan name is one that plan adds."
                        )

                        ForEach(Self.groups) { group in
                            Controls.card(group.title) {
                                VStack(spacing: 0) {
                                    ForEach(Array(group.features.enumerated()), id: \.element.id) { index, feature in
                                        row(feature)
                                        if index < group.features.count - 1 { Controls.divider }
                                    }
                                }
                            }
                        }

                        // Where the subscription actually changes something, said once and plainly,
                        // rather than implied by what is missing from the cards above.
                        Controls.card(
                            "What a plan changes",
                            footer: "Connecting over your own network is unlimited on every plan, including the free one. Relay time is the only thing metered."
                        ) {
                            VStack(spacing: 0) {
                                ForEach(Array(StoreManager.Tier.allCases.enumerated()), id: \.element.id) { index, tier in
                                    Controls.row(tier.name, systemImage: tier == .pro ? "sparkles" : "clock") {
                                        Text(self.summary(for: tier))
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.secondary)
                                    }
                                    if index < StoreManager.Tier.allCases.count - 1 { Controls.divider }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                    .padding(.bottom, 36)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }

    /// One feature: the glyph, what it is, and what it means in a sentence.
    ///
    /// Two lines rather than one, because half of these names are the app's own shorthand and the
    /// sentence under them is where a reader finds out whether it is the thing they hoped for.
    private func row(_ feature: PlanFeature) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Controls.icon(feature.icon)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(feature.title)
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)

                    if let plan = feature.plan {
                        Text(plan.name.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(ColorPalette.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(ColorPalette.accent.opacity(0.18), in: Capsule())
                    }
                }

                Text(feature.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
    }

    /// What a tier buys, in the two numbers that differ: relay time and Macs.
    ///
    /// Both on one line because they are one decision. A reader comparing three rows is comparing
    /// two facts about each, and splitting them into two tables makes the middle row look like two
    /// separate choices rather than one worse one.
    private func summary(for tier: StoreManager.Tier) -> String {
        let allowance: String
        switch tier {
        case .relay: allowance = "3 hours a day"
        case .relayPlus, .pro: allowance = "No limit"
        }
        return "\(allowance) · \(tier.macCount)"
    }

    /// The inventory.
    ///
    /// Written from the app rather than from ambition: every line here is something a user can do
    /// in the build they have. Anything not built yet does not get a line, because a feature list
    /// that describes the roadmap is a list that makes the paywall a lie in the one place it is
    /// least affordable.
    ///
    /// Order matters and follows the way the app is met: connect, look, drive, open a shell, and
    /// then the things that keep working once the app is in the background.
    static let groups: [PlanFeatureGroup] = [
        PlanFeatureGroup(title: "Connecting", features: [
            PlanFeature(
                icon: "lock.shield",
                title: "Pair once, with no account",
                detail: "Two devices confirm a six-digit code and keep their own keys. Nothing is stored on a server."
            ),
            PlanFeature(
                icon: "wifi",
                title: "Nearby, or by address",
                detail: "Pick your Mac from the list it broadcasts, or type an address when the network hides it."
            ),
            PlanFeature(
                icon: "network",
                title: "Reachable from another network",
                detail: "The relay finds your Mac when it is somewhere else. It carries the session without being able to read it."
            ),
            PlanFeature(
                icon: "arrow.left.arrow.right",
                title: "Straight between the two",
                detail: "When the networks allow it, the picture takes a path the two devices find for themselves, and only the control connection goes through the relay."
            ),
            PlanFeature(
                icon: "qrcode.viewfinder",
                title: "Pair a Mac that is not nearby",
                detail: "Scan the code a Mac shows to pair without ever being on the same network as it."
            ),
            PlanFeature(
                icon: "pencil.line",
                title: "Your Macs, named how you like",
                detail: "Rename a paired Mac to something you recognise, or forget one you are done with. Both are on the row itself, in the list you connect from."
            ),
            PlanFeature(
                icon: "wifi.exclamationmark",
                title: "Says so when the network goes",
                detail: "A session the network has stopped carrying ends and tells you rather than sitting on a frozen picture, so you can reconnect instead of waiting on a screen that will never move again."
            ),
            PlanFeature(
                icon: "faceid",
                title: "Face ID to open",
                detail: "Require Face ID each time the app comes back, so a locked phone is the only thing that unlocks the Mac."
            ),
            PlanFeature(
                icon: "power",
                title: "Wake a sleeping Mac",
                detail: "Send a wake-up packet, then connect. It reaches a Mac on your own network, not one across the internet.",
                plan: .pro
            ),
        ]),

        PlanFeatureGroup(title: "The picture", features: [
            PlanFeature(
                icon: "macwindow",
                title: "A display, an app, or one window",
                detail: "Every display the Mac is attached to, a single application, or one window. Switch between them without reconnecting.",
                plan: .pro
            ),
            PlanFeature(
                icon: "rectangle.3.group",
                title: "Every desktop you have",
                detail: "All your Spaces, each drawn as a picture rather than as a number to guess at. Tap one to move the Mac to it."
            ),
            PlanFeature(
                icon: "arrow.up.forward.app",
                title: "Open an app you forgot to launch",
                detail: "The list includes applications that are installed but not running. Tap one and the Mac opens it, then it becomes a source like any other."
            ),
            PlanFeature(
                icon: "arrow.triangle.swap",
                title: "Which path the picture took",
                detail: "The session's info panel names the path in use and shows the round trip of the lane the picture is on, separately from the control connection's, so a session going straight is not measured by the relay's numbers."
            ),
            PlanFeature(
                icon: "speedometer",
                title: "Picture matched to the network",
                detail: "The bitrate follows what the connection can carry, so a weak link degrades instead of stalling. You can also pin it to Low, Medium or High yourself."
            ),
            PlanFeature(
                icon: "speaker.wave.2",
                title: "Sound from the Mac",
                detail: "Hear what is playing on the Mac, from music you left running to the alert it makes in answer to a key you sent it. One switch in the session panel, and turning it off only drops the sound here.",
                plan: .pro
            ),
            PlanFeature(
                icon: "pip",
                title: "Picture in Picture",
                detail: "Keep the Mac's screen floating over other apps while you do something else.",
                plan: .pro
            ),
            PlanFeature(
                icon: "moon.fill",
                title: "Privacy mode",
                detail: "Dim the Mac's own displays while you work, so nobody standing there watches along.",
                plan: .pro
            ),
            PlanFeature(
                icon: "camera",
                title: "Screenshots",
                detail: "Capture what you are looking at and send it through the usual share sheet."
            ),
        ]),

        PlanFeatureGroup(title: "Driving it", features: [
            PlanFeature(
                icon: "hand.point.up.left",
                title: "Touch, and zoom",
                detail: "Tap and drag to control the Mac; pinch to zoom in and out of the picture."
            ),
            PlanFeature(
                icon: "macbook.and.iphone",
                title: "Trackpad, pointer and scroll wheel",
                detail: "A relative pointer for the small corrections a fingertip cannot make, and a notched wheel that scrolls the Mac a line at a time."
            ),
            PlanFeature(
                icon: "keyboard",
                title: "Keyboard, on screen or attached",
                detail: "Type with the system keyboard or a Bluetooth one, with the modifier keys the Mac expects."
            ),
            PlanFeature(
                icon: "eye",
                title: "Observe without touching",
                detail: "A mode that shows the screen and sends no input at all."
            ),
            PlanFeature(
                icon: "lock.fill",
                title: "Lock the Mac, or darken it",
                detail: "Lock the Mac from the session screen, or put its displays out without ending the session."
            ),
            PlanFeature(
                icon: "doc.on.clipboard",
                title: "Clipboard, and its history",
                detail: "Pull the Mac's clipboard onto the phone, and keep what you pulled earlier."
            ),
            PlanFeature(
                icon: "wand.and.stars",
                title: "Macros",
                detail: "Save a sequence and fire it with one tap, for the things you type every time.",
                plan: .pro
            ),
            PlanFeature(
                icon: "text.badge.plus",
                title: "Snippets and quick commands",
                detail: "The commands you keep one tap away, above the keyboard, in every terminal.",
                plan: .pro
            ),
        ]),

        PlanFeatureGroup(title: "Terminals and files", features: [
            PlanFeature(
                icon: "terminal",
                title: "A shell on your Mac",
                detail: "Open a terminal inside the session, with tabs you can name, and the control keys a phone keyboard cannot send.",
                plan: .relayPlus
            ),
            PlanFeature(
                icon: "clock.arrow.circlepath",
                title: "Commands you ran before",
                detail: "The last commands sent to a shell, one tap from the input field. A command the shell did not recognise is dropped from the list."
            ),
            PlanFeature(
                icon: "server.rack",
                title: "SSH servers",
                detail: "Saved hosts, passwords in the Keychain, the fingerprint shown the first time, and a Face ID or passcode lock you can put on any one of them."
            ),
            PlanFeature(
                icon: "folder",
                title: "Browse by tapping",
                detail: "Walk a folder tree on either machine, change directory and preview a file without typing a path."
            ),
            PlanFeature(
                icon: "pencil",
                title: "Read and change a file",
                detail: "Open a text file, edit it and save it back, with the file's own permissions kept. Reading and editing are the same surface, so wrapping behaves the same in both. A file too long to show whole is read but not offered for editing, because saving it would throw the rest away."
            ),
            PlanFeature(
                icon: "photo",
                title: "A picture is shown as a picture",
                detail: "What a file is comes from its own bytes rather than its name: an image opens as an image, and an SVG is drawn with scripts off. Something that is neither text nor a picture is refused rather than shown as rubbish."
            ),
            PlanFeature(
                icon: "folder.badge.plus",
                title: "Make, rename and delete",
                detail: "A new file or folder, a rename on any row, and a delete that says what it will take with it. On your Mac, deleting moves it to the Bin; on an SSH server it says plainly that it cannot be undone."
            ),
            PlanFeature(
                icon: "play.circle",
                title: "Run what you are looking at",
                detail: "An executable row carries a Run button, confirmed by its name and path. What it sends is a line typed into a shell you already have, so a script that prints something prints it where you can see it."
            ),
            PlanFeature(
                icon: "square.and.arrow.up",
                title: "Take a file off the machine",
                detail: "Download what you are looking at to the phone and hand it to Files, or to anything else in the share sheet."
            ),
            PlanFeature(
                icon: "arrow.up.to.line",
                title: "Send a file to it",
                detail: "Pick a file from the phone and put it in the folder you are looking at, up to 64 MB."
            ),
        ]),

        PlanFeatureGroup(title: "Around the app", features: [
            PlanFeature(
                icon: "bolt.horizontal.circle",
                title: "Live Activity",
                detail: "The session's state and duration on the Lock Screen and in the Dynamic Island.",
                plan: .relayPlus
            ),
            PlanFeature(
                icon: "square.grid.2x2",
                title: "Home Screen widget",
                detail: "One tap to open Peering on the Mac you used last.",
                plan: .relayPlus
            ),
            PlanFeature(
                icon: "bell",
                title: "Told when you are needed",
                detail: "A notification when a Mac is waiting on a pairing code, a password prompt, or a terminal that has stopped for an answer."
            ),
            PlanFeature(
                icon: "chart.bar",
                title: "What you have used",
                detail: "The Sessions tab counts relay time against the day's allowance, so the meter is visible before it runs out."
            ),
            PlanFeature(
                icon: "clock.arrow.circlepath",
                title: "Session history",
                detail: "What connected, for how long, how much it moved, and whether that session went straight to the Mac or around through the relay."
            ),
            PlanFeature(
                icon: "mic",
                title: "Siri and Shortcuts",
                detail: "Ask to connect, or to end what is open, without opening the app."
            ),
        ]),
    ]
}

#Preview {
    PlanFeaturesView()
}
