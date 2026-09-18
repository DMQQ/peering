import SwiftUI

/// One thing the app does, and the plan it needs if it needs one.
///
/// `plan` is `nil` for everything today, and that is not an oversight: nothing in this app is
/// gated on a subscription except relay time, which the plan cards already state. The field exists
/// so that adding a gate later is editing this table rather than rewriting this screen — fill it
/// in and the row draws its badge, with no other change anywhere.
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
/// decision and the wrong length for an inventory — so the sheet carries a way to see the whole
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
                            detail: "Every plan runs the whole app. What differs is how much relay time you get."
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
                            footer: "Relay time is the only thing metered today. Local connections are unlimited on every plan, including the free one."
                        ) {
                            VStack(spacing: 0) {
                                ForEach(Array(StoreManager.Tier.allCases.enumerated()), id: \.element.id) { index, tier in
                                    Controls.row(tier.name, systemImage: tier == .pro ? "sparkles" : "clock") {
                                        Text(self.allowance(for: tier))
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

    private func allowance(for tier: StoreManager.Tier) -> String {
        switch tier {
        case .relay: return "3 hours a day"
        case .relayPlus, .pro: return "No limit"
        }
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
                icon: "qrcode.viewfinder",
                title: "Pair a Mac that is not nearby",
                detail: "Scan the code a Mac shows to pair without ever being on the same network as it."
            ),
            PlanFeature(
                icon: "power",
                title: "Wake a sleeping Mac",
                detail: "Send a wake-up packet, then connect. No walking over to press a key."
            ),
            PlanFeature(
                icon: "faceid",
                title: "Face ID to open",
                detail: "Require Face ID each time the app comes back, so a locked phone is the only thing that unlocks the Mac."
            ),
        ]),

        PlanFeatureGroup(title: "The picture", features: [
            PlanFeature(
                icon: "macwindow",
                title: "A display, an app, or one window",
                detail: "Share the whole screen, a single application, or one window. Switch without reconnecting."
            ),
            PlanFeature(
                icon: "rectangle.3.group",
                title: "Every desktop you have",
                detail: "All your Spaces, each drawn as a picture rather than as a number to guess at."
            ),
            PlanFeature(
                icon: "speedometer",
                title: "Picture matched to the network",
                detail: "The bitrate follows what the connection can carry, so a weak link degrades instead of stalling."
            ),
            PlanFeature(
                icon: "speaker.wave.2",
                title: "Sound from the Mac",
                detail: "Hear what is playing on the Mac, with a mute when you would rather not."
            ),
            PlanFeature(
                icon: "pip",
                title: "Picture in Picture",
                detail: "Keep the Mac's screen floating over other apps while you do something else."
            ),
            PlanFeature(
                icon: "moon.fill",
                title: "Privacy mode",
                detail: "Dim the Mac's own displays while you work, so nobody standing there watches along."
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
                title: "Trackpad and scroll wheel",
                detail: "A relative pointer for the small corrections a fingertip cannot make precisely."
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
                icon: "doc.on.clipboard",
                title: "Clipboard, and its history",
                detail: "Pull the Mac's clipboard onto the phone, and keep what you pulled earlier."
            ),
            PlanFeature(
                icon: "wand.and.stars",
                title: "Macros",
                detail: "Save a sequence and fire it with one tap, for the things you type every time."
            ),
            PlanFeature(
                icon: "text.badge.plus",
                title: "Snippets and quick commands",
                detail: "The commands you keep one tap away, above the keyboard, in every terminal."
            ),
        ]),

        PlanFeatureGroup(title: "Terminals and files", features: [
            PlanFeature(
                icon: "terminal",
                title: "A shell on your Mac",
                detail: "Open a terminal inside the session, with tabs, without leaving the app."
            ),
            PlanFeature(
                icon: "server.rack",
                title: "SSH servers",
                detail: "Saved hosts, keys kept in the Keychain, and the fingerprint shown the first time."
            ),
            PlanFeature(
                icon: "folder",
                title: "Browse by tapping",
                detail: "Walk a folder tree on either machine, change directory and preview a file without typing a path."
            ),
        ]),

        PlanFeatureGroup(title: "Around the app", features: [
            PlanFeature(
                icon: "bolt.horizontal.circle",
                title: "Live Activity",
                detail: "The session's state and duration on the Lock Screen and in the Dynamic Island."
            ),
            PlanFeature(
                icon: "square.grid.2x2",
                title: "Home Screen widget",
                detail: "One tap to open Peering on the Mac you used last."
            ),
            PlanFeature(
                icon: "bell",
                title: "Told when you are needed",
                detail: "A notification when a Mac is waiting on a pairing code or a password prompt."
            ),
            PlanFeature(
                icon: "clock.arrow.circlepath",
                title: "Session history",
                detail: "What connected, for how long, over which path, and how much it moved."
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
