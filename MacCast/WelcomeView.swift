import SwiftUI

/// The first thing the app ever shows, and the only screen in it written for someone who has
/// not decided yet whether they want it.
///
/// Two stages behind one flag. The landing is the claim; the tour behind it is the detail, and
/// only a user who asks for it gets it. Someone who is here because they already know what they
/// want is one tap from the host list — which is the whole reason ``skip`` exists rather than a
/// back button.
///
/// It sits *in front of* ``HostPickerView`` rather than replacing it. The picker's own header is
/// already a kind of landing — the name, the tagline, the drawing of the two devices — and
/// duplicating that here would make the second screen of the app look like the first one
/// arriving twice. This one leads with the mark and the claim; that one leads with what it can
/// currently see on your network.
struct WelcomeFlow: View {
    /// Set when the user is done, however they got there.
    var onFinish: () -> Void

    @State private var stage: Stage = .landing

    private enum Stage { case landing, tour }

    var body: some View {
        ZStack {
            switch stage {
            case .landing:
                LandingView(
                    onStart: { withAnimation(Motion.settle) { stage = .tour } },
                    onSkip: onFinish
                )
                .transition(.opacity)
            case .tour:
                OnboardingView(onFinish: onFinish)
                    .transition(.opacity)
            }
        }
        // Both stages are portrait. `ContentView` already pins everything that is not the remote
        // screen; this is only here so the transition between the two stages cannot halfway
        // rotate under a device that is being moved while the flow is on screen.
        .preferredColorScheme(.dark)
    }
}

/// The hero, the claims, and the two ways out.
private struct LandingView: View {
    var onStart: () -> Void
    var onSkip: () -> Void

    var body: some View {
        ZStack {
            ColorPalette.backdrop.ignoresSafeArea()
            light

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    hero
                    claims
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 24)
                // Fills the viewport and centres the block inside it, which is the other half of
                // what was wrong with this screen: with the card gone the content came up short,
                // and a short page under a pinned button pools every spare point in one gap above
                // it. Centred, the same space is split above and below and reads as margin rather
                // than as something missing. Taller content still scrolls, unchanged.
                .containerRelativeFrame(.vertical, alignment: .center)
            }
            // Outside the scroll view, so the way forward is on screen from the first frame.
            // It was the last thing in the stack, which put both buttons below the fold on a
            // phone — a landing screen whose only exit has to be scrolled for is a landing
            // screen that reads as a wall.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actions
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
                    .padding(.top, 34)
                    .background {
                        // A fade rather than a bar. A material edge would put a visible line
                        // across a page that is one continuous surface; this lets the last
                        // claim dissolve under the buttons instead of being cut off by them.
                        //
                        // Opaque from 40% down rather than at the very bottom, and that is the
                        // fix for a gradient that ran past the buttons: `ignoresSafeArea` takes
                        // the gradient to the physical bottom of the display, which is below
                        // where the buttons end — so with the fade still going at the last
                        // button, the page showed through it. The stops put the solid part
                        // under everything the user can press.
                        LinearGradient(
                            stops: [
                                .init(color: ColorPalette.backdrop.opacity(0), location: 0),
                                .init(color: ColorPalette.backdrop, location: 0.4)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .ignoresSafeArea()
                    }
            }

            // Last in the stack, so it sits over the scroll view rather than in it. It must not
            // scroll away: the one thing it is for is being findable on the way in, by someone
            // who has already decided this is not what they wanted.
            SkipButton(action: onSkip)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    /// The mark, the name, and the one sentence the whole app exists to make true.
    ///
    /// The artwork is the icon's two pears with the icon's own background lifted out — see the
    /// `Pears` asset, which is that PNG with the plate keyed to transparency. Drawn rather than
    /// presented as the app icon, because a rounded-square tile is what an icon looks like in a
    /// place that is *listing* apps, and this screen is not one of those.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image("Pears")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text("Peering")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .tracking(-1.5)

                // The whole opening statement, and there is deliberately nothing else under it.
                // A sentence explaining what the app is used to sit here; it said what this line
                // already says, and two lines of prose above five rows of claims is how a first
                // screen turns into something to get past rather than something to read.
                Text("Your Mac, in your pocket.")
                    .font(.system(.title3, design: .rounded).weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 14)
    }

    /// What it does, in the order someone deciding would ask.
    ///
    /// Every line is checkable against the app, and the two that most often need correcting are
    /// answered here rather than only in the FAQ: there is a relay, and it is named as one; and
    /// the encryption is described as what it is — the two devices authenticating each other,
    /// not a promise about a server that cannot read what it carries anyway.
    private var claims: some View {
        VStack(alignment: .leading, spacing: 12) {
            Claim(
                icon: "lock.shield",
                title: "Encrypted, device to device",
                detail: "TLS 1.3, pinned on first pairing. No account, nothing stored."
            )
            Claim(
                icon: "hand.point.up.left",
                title: "You actually drive it",
                detail: "Pointer, keyboard, joystick, scroll wheel, macros."
            )
            Claim(
                icon: "macwindow",
                title: "A screen, an app, or one window",
                detail: "Share any of them. Switch without reconnecting."
            )
            Claim(
                icon: "rectangle.split.3x1",
                title: "Every desktop you have",
                detail: "All your Spaces, each shown as a picture."
            )
            Claim(
                icon: "pip",
                title: "Keeps going when you leave",
                detail: "Picture in Picture, Live Activity, widget."
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        WelcomePrimaryButton(title: "Get started", action: onStart)
    }

    /// One soft light from the top, the same one the host picker uses. A single flat near-black
    /// reads as a hole rather than as a surface; this gives it a direction without adding a
    /// colour, which the palette does not have to spare.
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
}

/// The two ways out of the introduction: in, or past.
///
/// One view rather than one per stage, and that is not tidiness. The landing and the tour are
/// the same two buttons at the bottom of two screens a swipe apart, and as two copies they had
/// already come to rest at different heights and different sizes — the kind of thing that reads
/// as sloppiness the moment you swipe between them, without anyone being able to say why.
struct WelcomePrimaryButton: View {
    let title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(ColorPalette.ink)
        .foregroundStyle(.black)
        // The title changes under the finger between the last page and the one before it.
        // Swapping the word without animating it keeps that a label change rather than a button
        // that shrinks and grows as it is pressed.
        .animation(nil, value: title)
    }
}

/// The way past the introduction.
///
/// Top-right and on its own, rather than tucked under the button it is an alternative to. At the
/// bottom the two sat two points apart and read as a pair of equal choices, which they are not:
/// one is the way in and the other is the door out. Up here it is clear of the primary action
/// and still exactly where iOS puts this.
struct SkipButton: View {
    var action: () -> Void

    var body: some View {
        Button("Skip", action: action)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .buttonStyle(RailButtonStyle(scale: 0.98))
            .padding(.horizontal, 18)
            .padding(.top, 6)
    }
}

/// One claim: a glyph, a phrase, and the sentence that makes it true.
private struct Claim: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(ColorPalette.ink)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 13)
        .rowSurface()
    }
}

#Preview {
    WelcomeFlow(onFinish: {})
        .preferredColorScheme(.dark)
}
