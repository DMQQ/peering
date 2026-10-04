import MacCastKit
import SwiftUI

/// One thing the app does, and the plan it needs if it needs one.
///
/// `capability` is `nil` for everything the free plan includes, which is most of the app. Where it
/// is set, the row draws a badge, and the badge is **read off the capability**, not typed onto
/// the row, because the badge on this row and the badge drawn on the control it describes are
/// the same fact seen from two screens. ``PlanCapability`` is where that fact lives; the two screens
/// are one tap apart and a feature that is free here and gated there is not a difference of opinion,
/// it is a page contradicting itself.
///
/// **The badges are the map, and so are the gates.** Every line below that wears a plan name is a
/// control that is gated on that plan, and every line with no badge is something the app does not
/// gate at all. That is checkable against the build rather than against an intention, and
/// `MacCastKitTests.PlanAccessTests` is where the map those two read is itself held still.
struct PlanFeature: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let detail: String
    var capability: PlanCapability?

    /// The plan name on the badge, or `nil` for a row every plan includes.
    var planName: String? { capability?.minimumPlan.name }
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
                            String(localized: "Everything included"),
                            detail: String(localized: "Most of the app is in every plan, the free one included. A row wearing a plan name is one that plan adds.")
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
                            String(localized: "What a plan changes"),
                            footer: String(localized: "Connecting over your own network is unlimited on every plan, including the free one, and every paid plan pairs with every Mac you own. Free pairs with one. Relay time is the only thing metered.")
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

                    if let plan = feature.planName {
                        Text(plan.uppercased())
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
        "\(tier.plan.allowanceSpelling.capitalized) · \(StoreManager.Tier.macCount)"
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
        PlanFeatureGroup(title: String(localized: "Connecting"), features: [
            PlanFeature(
                icon: "lock.shield",
                title: String(localized: "Pair once, with no account"),
                detail: String(localized: "Two devices confirm a six-digit code and keep their own keys. Nothing is stored on a server.")
            ),
            PlanFeature(
                icon: "wifi",
                title: String(localized: "Nearby, or by address"),
                detail: String(localized: "Pick your Mac from the list it broadcasts, or type an address when the network hides it.")
            ),
            PlanFeature(
                icon: "network",
                title: String(localized: "Reachable from another network"),
                detail: String(localized: "The relay finds your Mac when it is somewhere else. It carries the session without being able to read it.")
            ),
            PlanFeature(
                icon: "arrow.left.arrow.right",
                title: String(localized: "Straight between the two"),
                detail: String(localized: "When the networks allow it, the picture takes a path the two devices find for themselves, and only the control connection goes through the relay.")
            ),
            PlanFeature(
                icon: "qrcode.viewfinder",
                title: String(localized: "Pair a Mac that is not nearby"),
                detail: String(localized: "Scan the code a Mac shows to pair without ever being on the same network as it.")
            ),
            PlanFeature(
                icon: "pencil.line",
                title: String(localized: "Your Macs, named how you like"),
                detail: String(localized: "Rename a paired Mac to something you recognise, or forget one you are done with. Both are on the row itself, in the list you connect from.")
            ),
            PlanFeature(
                icon: "wifi.exclamationmark",
                title: String(localized: "Says so when the network goes"),
                detail: String(localized: "A session the network has stopped carrying ends and tells you rather than sitting on a frozen picture, so you can reconnect instead of waiting on a screen that will never move again.")
            ),
            PlanFeature(
                icon: "faceid",
                title: String(localized: "Biometrics to open"),
                detail: String(localized: "Require Face ID or Touch ID each time the app comes back, so a locked phone is the only thing that unlocks the Mac.")
            ),
            PlanFeature(
                icon: "power",
                title: String(localized: "Wake a sleeping Mac"),
                detail: String(localized: "Send a wake-up packet, then connect. It reaches a Mac on your own network, not one across the internet.")
            ),
        ]),

        PlanFeatureGroup(title: String(localized: "The picture"), features: [
            PlanFeature(
                icon: "macwindow",
                title: String(localized: "A display, an app, or one window"),
                detail: String(localized: "Every display the Mac is attached to, a single application, or one window. Switch between them without reconnecting.")
            ),
            PlanFeature(
                icon: "rectangle.3.group",
                title: String(localized: "Every desktop you have"),
                detail: String(localized: "All your Spaces, each drawn as a picture rather than as a number to guess at. Tap one to move the Mac to it.")
            ),
            PlanFeature(
                icon: "arrow.up.forward.app",
                title: String(localized: "Open an app you forgot to launch"),
                detail: String(localized: "The list includes applications that are installed but not running. Tap one and the Mac opens it, then it becomes a source like any other.")
            ),
            PlanFeature(
                icon: "arrow.triangle.swap",
                title: String(localized: "Which path the picture took"),
                detail: String(localized: "The session's info panel names the path in use and shows the round trip of the lane the picture is on, separately from the control connection's, so a session going straight is not measured by the relay's numbers.")
            ),
            PlanFeature(
                icon: "sparkles.tv",
                title: String(localized: "The sharpest picture over the relay"),
                detail: String(localized: "A relayed session climbs to 20 Mbps, five times what it reaches without this. On your own network nothing is capped on any plan, because those bytes are not going through anything of ours."),
                capability: .highBitrate
            ),
            PlanFeature(
                icon: "speedometer",
                title: String(localized: "Picture matched to the network"),
                detail: String(localized: "The bitrate follows what the connection can carry, so a weak link degrades instead of stalling. You can also pin it to Low, Medium or High yourself.")
            ),
            PlanFeature(
                icon: "speaker.wave.2",
                title: "Sound from the Mac",
                detail: String(localized: "Hear what is playing on the Mac, from music you left running to the alert it makes in answer to a key you sent it. One switch in the session panel, and turning it off only drops the sound here."),
                capability: .macSound
            ),
            PlanFeature(
                icon: "pip",
                title: String(localized: "Picture in Picture"),
                detail: String(localized: "Keep the Mac's screen floating over other apps while you do something else."),
                capability: .pictureInPicture
            ),
            PlanFeature(
                icon: "clock.arrow.circlepath",
                title: String(localized: "Clipboard history"),
                detail: String(localized: "The last twelve things that crossed between the two machines, waiting to be pasted again. Copying and pasting themselves are on every plan."),
                capability: .clipboardHistory
            ),
            PlanFeature(
                icon: "moon.fill",
                title: String(localized: "Privacy mode"),
                detail: String(localized: "Dim the Mac's own displays while you work, so nobody standing there watches along.")
            ),
            PlanFeature(
                icon: "camera",
                title: String(localized: "Screenshots"),
                detail: String(localized: "Capture what you are looking at and send it through the usual share sheet.")
            ),
        ]),

        PlanFeatureGroup(title: String(localized: "Driving it"), features: [
            PlanFeature(
                icon: "hand.point.up.left",
                title: String(localized: "Touch, and zoom"),
                detail: String(localized: "Tap and drag to control the Mac; pinch to zoom in and out of the picture.")
            ),
            PlanFeature(
                icon: "macbook.and.iphone",
                title: String(localized: "Trackpad, pointer and scroll wheel"),
                detail: String(localized: "A relative pointer for the small corrections a fingertip cannot make, and a notched wheel that scrolls the Mac a line at a time.")
            ),
            PlanFeature(
                icon: "keyboard",
                title: String(localized: "Keyboard, on screen or attached"),
                detail: String(localized: "Type with the system keyboard or a Bluetooth one, with the modifier keys the Mac expects.")
            ),
            PlanFeature(
                icon: "eye",
                title: String(localized: "Observe without touching"),
                detail: String(localized: "A mode that shows the screen and sends no input at all.")
            ),
            PlanFeature(
                icon: "lock.fill",
                title: String(localized: "Lock the Mac, or darken it"),
                detail: String(localized: "Lock the Mac from the session screen, or put its displays out without ending the session.")
            ),
            PlanFeature(
                icon: "doc.on.clipboard",
                title: String(localized: "Clipboard, and its history"),
                detail: String(localized: "Pull the Mac's clipboard onto the phone, and keep what you pulled earlier.")
            ),
            PlanFeature(
                icon: "wand.and.stars",
                title: "Macros",
                detail: String(localized: "Save a sequence and fire it with one tap, for the things you type every time."),
                capability: .macros
            ),
            PlanFeature(
                icon: "text.badge.plus",
                title: String(localized: "Snippets and quick commands"),
                detail: String(localized: "The commands you keep one tap away, above the keyboard, in every terminal."),
                capability: .macros
            ),
        ]),

        PlanFeatureGroup(title: String(localized: "Terminals and files"), features: [
            PlanFeature(
                icon: "terminal",
                title: String(localized: "A shell on your Mac"),
                detail: String(localized: "Open a terminal inside the session, with the control keys a phone keyboard cannot send. It runs on the Mac rather than here, and it keeps going when you disconnect.")
            ),
            // **The row that says what the concurrency costs, and the one that was missing.** It
            // used to be implied by the line above, which said "with tabs you can name" and wore no
            // badge, so the list promised tabs and the plans document sold them, and the one screen
            // a reader checks before paying was the one that got it wrong. It is its own row now,
            // for the same reason it is its own row on the cards: one shell is free, the second one
            // at the same time is not, and that is a sentence no single line can hold.
            PlanFeature(
                icon: "rectangle.stack",
                title: String(localized: "Several shells at once"),
                detail: String(localized: "One shell at a time is in every plan, on your Mac and on any server you have added. This is naming a tab and keeping several open, each with its own scrollback and its own directory."),
                capability: .shellTabs
            ),
            // The same line the paywall's own door for it uses, and deliberately: these two are
            // read minutes apart by the same person, and the row that reads well on its own is
            // the row that disagrees with the one beside it.
            PlanFeature(
                icon: "bell.badge",
                title: String(localized: "Told when a shell needs you"),
                detail: String(localized: "A banner when a shell on the Mac or on one of your servers stops and waits for you, on this device while the session is open and through the Mac when it is not. The terminal and the mark on its own tab are on every plan."),
                capability: .terminalAlerts
            ),
            // The same sentence the paywall's door for it uses, and the same care about what it
            // promises: the tiles are live pictures rather than stills, and the one thing a
            // reader has to know before buying is that the Mac is doing more work than it does
            // for one window.
            PlanFeature(
                icon: "rectangle.split.2x2",
                title: String(localized: "Several windows at once"),
                detail: String(localized: "Pick several of the Mac's windows, apps or displays and see them together, arranged on this screen. Each tile is captured live on the Mac rather than being a still, and tapping one takes you into it, with the whole arrangement waiting behind a back control."),
                capability: .mosaic
            ),
            PlanFeature(
                icon: "rectangle.badge.plus",
                title: String(localized: "Virtual displays"),
                detail: String(localized: "A screen the Mac does not physically have, made from this phone and looked at from it: somewhere else for its windows to go, named and taken away from the same list."),
                capability: .virtualDisplays
            ),
            PlanFeature(
                icon: "clock.arrow.circlepath",
                title: String(localized: "Commands you ran before"),
                detail: String(localized: "The last commands sent to a shell, one tap from the input field. A command the shell did not recognise is dropped from the list.")
            ),
            // **Free, and it was the one row that read as a hostage.** A server is a machine the
            // user typed in themselves and named themselves, and the row that said it needed Relay
            // Plus was the app asking to be paid for a list of their own hosts. What a plan runs
            // out of is shells at once, which is the row above this one, so this line carries no
            // capability and wears no badge.
            PlanFeature(
                icon: "server.rack",
                title: String(localized: "SSH servers"),
                detail: String(localized: "Saved hosts, passwords in the Keychain, the fingerprint shown the first time, and a Face ID or passcode lock you can put on any one of them.")
            ),
            PlanFeature(
                icon: "folder",
                title: String(localized: "Browse by tapping"),
                detail: String(localized: "Walk a folder tree on either machine, change directory and preview a file without typing a path.")
            ),
            PlanFeature(
                icon: "pencil",
                title: String(localized: "Read and change a file"),
                detail: String(localized: "Open a text file, edit it and save it back, with the file's own permissions kept. Reading and editing are the same surface, so wrapping behaves the same in both. A file too long to show whole is read but not offered for editing, because saving it would throw the rest away.")
            ),
            PlanFeature(
                icon: "photo",
                title: String(localized: "A picture is shown as a picture"),
                detail: String(localized: "What a file is comes from its own bytes rather than its name: an image opens as an image, and an SVG is drawn with scripts off. Something that is neither text nor a picture is refused rather than shown as rubbish.")
            ),
            PlanFeature(
                icon: "folder.badge.plus",
                title: String(localized: "Make, rename and delete"),
                detail: String(localized: "A new file or folder, a rename on any row, and a delete that says what it will take with it. On your Mac, deleting moves it to the Bin; on an SSH server it says plainly that it cannot be undone.")
            ),
            PlanFeature(
                icon: "play.circle",
                title: String(localized: "Run what you are looking at"),
                detail: String(localized: "An executable row carries a Run button, confirmed by its name and path. What it sends is a line typed into a shell you already have, so a script that prints something prints it where you can see it.")
            ),
            PlanFeature(
                icon: "square.and.arrow.up",
                title: String(localized: "Take a file off the machine"),
                detail: String(localized: "Download what you are looking at to the phone and hand it to Files, or to anything else in the share sheet."),
                capability: .fileTransfer
            ),
            PlanFeature(
                icon: "arrow.up.to.line",
                title: String(localized: "Send a file to it"),
                detail: String(localized: "Pick a file from the phone and put it in the folder you are looking at, up to 2 GB."),
                capability: .fileTransfer
            ),
        ]),

        PlanFeatureGroup(title: String(localized: "Around the app"), features: [
            PlanFeature(
                icon: "bolt.horizontal.circle",
                title: String(localized: "Live Activity"),
                detail: String(localized: "The session's state and duration on the Lock Screen and in the Dynamic Island.")
            ),
            PlanFeature(
                icon: "square.grid.2x2",
                title: String(localized: "Home Screen widget"),
                detail: String(localized: "One tap to open Peering on the Mac you used last.")
            ),
            PlanFeature(
                icon: "bell",
                title: String(localized: "Told when you are needed"),
                detail: String(localized: "A notification when a Mac is waiting on a pairing code, a password prompt, or a terminal that has stopped for an answer.")
            ),
            PlanFeature(
                icon: "chart.bar",
                title: String(localized: "What you have used"),
                detail: String(localized: "The Sessions tab counts relay time against the day's allowance, so the meter is visible before it runs out.")
            ),
            PlanFeature(
                icon: "clock.arrow.circlepath",
                title: String(localized: "Session history"),
                detail: String(localized: "What connected, for how long, how much it moved, and whether that session went straight to the Mac or around through the relay.")
            ),
            PlanFeature(
                icon: "mic",
                title: String(localized: "Siri and Shortcuts"),
                detail: String(localized: "Ask to connect, or to end what is open, without opening the app.")
            ),
        ]),
    ]
}

#Preview {
    PlanFeaturesView()
}
