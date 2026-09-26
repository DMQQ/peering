import MacCastKit
import RemoteCore
import SSHCore
import SwiftUI
import UIKit


extension View {
    /// A card arriving on the Connect screen, late enough after the one above it to be seen
    /// arriving.
    ///
    /// The delay is the whole point of it. All six cards are in place on the first frame
    /// otherwise, and a screen that is simply *there* when the header finishes moving reads as a
    /// screen that was always there — the eye takes the header as the only thing that happened.
    /// Each card coming up a twentieth of a second after the one above it is what makes the
    /// arrival read downward, in the order the screen wants to be read.
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

/// The Connect screen's own numbers: the margin its content keeps, and the two sizes the header
/// opens and rests at.
///
/// The sizes are here rather than written into the modifier that happens to use each one, because
/// they are a single decision — the header opens at one set and ends at the other — and six
/// constants scattered through a body is six chances for one of them to be left behind at a size
/// nothing else agrees with.
enum Hero {
    /// Named because the header measures its centring against the width that is left after the
    /// content's inset, so the number is needed in two places and has to be the same one.
    static let inset: CGFloat = 18
    /// Where the mark sits below the top of the header once it has arrived.
    static let topGap: CGFloat = 12
    /// The header's height at rest. It is fixed, and the hero is an offset from it.
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

    /// The mark, the name, and the two devices the name is about.
    ///
    /// The mark is the hero and the drawing of the devices is the footnote, which is the reverse of
    /// how this was built and is the whole of why the screen now opens on something worth looking
    /// at. The mark used to be a badge beside the wordmark, at 62 points, which is small enough
    /// that a solid pear and an outlined one stop being a mark and become a grey tile with
    /// something unreadable in it. It carries a display size perfectly well; the drawing of the two
    /// devices does not — at the top of the screen it was geometry, and what it means only arrives
    /// when the dots between them are moving, which is the one thing a large still frame cannot do.
    ///
    /// So they trade places. The mark is bare rather than in a tile, because a rounded square with
    /// a picture inside it is what an app icon looks like in a place that is *listing* apps, and the
    /// devices sit under the tagline where an illustration belongs — small enough to read as a
    /// diagram of what the sentence above it says, and animated, which is now the point of them
    /// rather than a detail nobody was looking at.
    ///
    /// The arrival is written as one journey in four numbers — how far the mark has appeared, how
    /// far the name has, and how far the pair has travelled left and up — rather than the four
    /// booleans it used to be, which is the difference between an animation and a set of states
    /// that happen to be switched at intervals. The distinction is not academic: three of the five
    /// things this header changes on the way to its corner were *layout* — the stack's alignment,
    /// the frame's alignment, and the font — and layout is not interpolated. The mark glided to the
    /// corner on a frame that was being resized a point at a time while the name beside it jumped,
    /// twice, and the pair of them crossed the middle of the screen on the way. Everything that
    /// moves here now moves through a number.
    ///
    /// The centring is measured rather than laid out, and that is the price of the rest of it.
    /// `alignment` is the free way to put a mark in the middle of a screen, and it is free because
    /// it is a decision the layout makes afresh each time rather than a value it can travel
    /// through — so the frame that centres the mark is also the frame that snaps it. Two labels are
    /// measured once, while the hero is standing still in the middle of the screen, and from then
    /// on the centring is an offset like every other part of the movement.
    func header(viewport: CGSize) -> some View {
        // The width the header has to centre against: the viewport's, less the inset the stack
        // this sits in keeps from both edges. Named in that stack's padding and here, which is why
        // it is named at all rather than written as 18 in two places and kept in step by hand.
        let width = max(viewport.width - Hero.inset * 2, 1)

        return VStack(alignment: .leading, spacing: 0) {
            // The frame is larger than the mark looks, and that is the mark's own doing: the
            // artwork carries a margin of its own, so a 72-point frame draws a pear about 52
            // points tall. Sized to what the drawing needs rather than to the number, so the
            // settled mark sits optically level with the wordmark under it.
            //
            // The two devices used to be drawn opposite it, across this row, and they have gone
            // to the connecting card — which is where the thing they draw is actually happening.
            // A header is a name and a promise; the moment a phone and a Mac are reaching for
            // each other is a moment, and it belongs on the screen that is about that moment.
            Image("Pears")
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
                // Measured while it is still, and only while it is. The name is resizing for the
                // whole of the journey to the corner, and a measurement that keeps arriving
                // mid-flight is a number the movement has to keep re-aiming at. What is wanted
                // from it is the width the name has *centred* — the state it is leaving, not the
                // one it is on its way to, whose offset is zero whatever this says.
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measured in
                    guard heroTravel == 0 else { return }
                    nameWidth = measured
                }

            Text("Your Mac, from anywhere.")
                // A text style rather than the point size the name under it travels through, so
                // this one line still answers to the reader's own text size. It is the copy here
                // and the name is the sign, and only one of those is allowed to be a picture.
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
        // The resting height, and only ever the resting height. It used to grow to fill the screen
        // while the header was centred, which is how the header was centred — the frame grew, the
        // stack centred itself inside it, and the height was pulled back to 202 at the fold. That
        // is the second thing that made the fold jump: both ends of it were layout. The frame is
        // now the header's own height whatever the hero is doing, and the hero's position in the
        // screen is an offset of its own.
        //
        // Shorter than it was when the devices were drawn under the type: what is left in the
        // header is a mark, two lines and a tagline, and the height that used to hold an
        // illustration below them would now be a gap above the first card.
        .frame(height: Hero.height, alignment: .topLeading)
        .padding(.top, Hero.topGap)
        // Down to the middle of the screen and back. Taken off the mark's middle rather than the
        // block's, because the mark is all there is to look at for the first half second of the
        // screen, and a pair of elements centred on their own middle puts the mark above the middle
        // of the screen — which is exactly where the name that has not arrived yet is going to go.
        .offset(y: (viewport.height / 2 - Hero.topGap - markSize / 2) * (1 - heroRise))
    }

    /// How far something has to move to sit in the middle of the header's width, less the part of
    /// that journey the hero has already made.
    func centred(_ size: CGFloat, in width: CGFloat) -> CGFloat {
        (width - size) / 2 * (1 - heroTravel)
    }

    /// The mark's size, which the header opens at and keeps its own half of the journey through.
    var markSize: CGFloat {
        Hero.restMark + (Hero.openMark - Hero.restMark) * (1 - heroTravel)
    }

    /// The gap under it, which closes as it sits down.
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

        // Four beats rather than one animation: the mark, then the name, then the header taking
        // its place at the top of the screen, then the cards. Each is a thing arriving, and a thing
        // that arrives at the same moment as three others has not been seen arriving at all.
        //
        // Every one of them is `Motion.arrive` — critically damped, so nothing here overshoots.
        // The header travels a long way, and a spring with give in it would run past where it was
        // going and come back with six cards animating underneath it, which is the bounce this
        // screen used to have.
        //
        // The third beat is the one with two curves in it. The leftward travel and the upward one
        // are told to start at the same moment and are given different shapes, and the mark takes
        // the path between them — which is a curve, because two curves that disagree at every
        // point but the last are how a curve is made out of two straight ones.
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
