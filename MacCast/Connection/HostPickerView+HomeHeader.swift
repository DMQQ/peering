import MacCastKit
import RemoteCore
import SSHCore
import SwiftUI
import UIKit


extension View {
    /// Late enough after the card above to be seen arriving, so the arrival reads downward.
    func connectEntrance(visible: Bool, delay: Double, reduceMotion: Bool) -> some View {
        opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : 14)
            .animation(
                reduceMotion
                    ? nil
                    : Motion.arrive.delay(delay),
                value: visible
            )
    }
}

enum Hero {
    /// Named because the header measures its centring against the width left after the content inset.
    static let inset: CGFloat = 18
    static let topGap: CGFloat = 12
    static let height: CGFloat = 202

    static let openMark: CGFloat = 136
    static let restMark: CGFloat = 72
    static let openName: CGFloat = 82
    static let restName: CGFloat = 60
    static let openTracking: CGFloat = -3.2
    static let restTracking: CGFloat = -2.2
    static let openGap: CGFloat = 26
    static let restGap: CGFloat = 16
}


extension HomeTab {
    // MARK: Header

    /// The mark is the hero and the two-device drawing the footnote. The arrival is one journey through four numbers, not booleans: the stack alignment, frame alignment and font were layout, which is not interpolated, so the mark glided while the name jumped.
    /// The centring is an offset measured once while the hero is still, since `alignment` snaps.
    func header(viewport: CGSize) -> some View {
        let width = max(viewport.width - Hero.inset * 2, 1)

        return VStack(alignment: .leading, spacing: 0) {
            // The frame is larger than the mark looks: the artwork carries its own margin, so a 72-point frame draws a pear about 52 points tall, which sits optically level with the wordmark.
            Image(String(localized: "Pears"))
                .resizable()
                .scaledToFit()
                .frame(width: markSize, height: markSize)
                .scaleEffect(markZoom)
                .opacity(markZoom)
                .padding(.bottom, markGap)
                .offset(x: centred(markSize, in: width))
                .accessibilityHidden(true)

            Wordmark(size: nameSize, tracking: nameTracking)
                .opacity(titleReveal)
                .offset(
                    x: centred(nameWidth, in: width),
                    y: 14 * (1 - titleReveal)
                )
                // Measured only while still: the name resizes for the whole journey, and a measurement arriving mid-flight keeps re-aiming the movement. Wanted is the width it has centred, the state it leaves.
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measured in
                    guard heroTravel == 0 else { return }
                    nameWidth = measured
                }

            Text("Your Mac, from anywhere.")
                // A text style rather than a point size, so this line follows the reader's text size.
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
                .opacity(titleReveal)
                .offset(
                    x: centred(taglineWidth, in: width),
                    y: 10 * (1 - titleReveal)
                )
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measured in
                    guard heroTravel == 0 else { return }
                    taglineWidth = measured
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Only ever the resting height: it used to grow to centre the header and snap back at the fold, which made the fold jump. The hero's position is its own offset.
        .frame(height: Hero.height, alignment: .topLeading)
        .padding(.top, Hero.topGap)
        // Taken off the mark's middle rather than the block's: the mark is all there is for the first half second, and centring the block would put the mark above the screen's middle.
        .offset(y: (viewport.height / 2 - Hero.topGap - markSize / 2) * (1 - heroRise))
    }

    func centred(_ size: CGFloat, in width: CGFloat) -> CGFloat {
        (width - size) / 2 * (1 - heroTravel)
    }

    var markSize: CGFloat {
        Hero.restMark + (Hero.openMark - Hero.restMark) * (1 - heroTravel)
    }

    var markGap: CGFloat {
        Hero.restGap + (Hero.openGap - Hero.restGap) * (1 - heroTravel)
    }

    var nameSize: CGFloat {
        Hero.restName + (Hero.openName - Hero.restName) * (1 - heroTravel)
    }

    var nameTracking: CGFloat {
        Hero.restTracking + (Hero.openTracking - Hero.restTracking) * (1 - heroTravel)
    }

    func runEntrance() {
        guard !entranceStarted else { return }
        entranceStarted = true
        let alreadyPlayed = Self.entranceHasPlayed
        Self.entranceHasPlayed = true
        guard !reduceMotion, !alreadyPlayed else {
            markZoom = 1
            titleReveal = 1
            heroTravel = 1
            heroRise = 1
            sectionsVisible = true
            return
        }

        // Four beats so each thing is seen arriving. Every one is `Motion.arrive`, critically damped: a spring with give would overshoot over a long travel with six cards animating beneath it.
        // The third beat gives the leftward and upward travel different curves, so the mark's path is a curve.
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            withAnimation(Motion.arrive) { markZoom = 1 }

            try? await Task.sleep(for: .milliseconds(520))
            withAnimation(Motion.arrive) { titleReveal = 1 }

            try? await Task.sleep(for: .milliseconds(600))
            withAnimation(Motion.travel) { heroTravel = 1 }
            withAnimation(Motion.rise) { heroRise = 1 }

            try? await Task.sleep(for: .milliseconds(620))
            withAnimation(Motion.arrive) { sectionsVisible = true }
        }
    }

}
