import MacCastKit
import StoreKit
import SwiftUI
import UIKit

/// The frame's numbers, outside the view because a generic type cannot hold static storage — and
/// named in one place, as the Connect header's are, because they are one decision about a shape.
enum PhoneStageMetrics {
    /// The screenshot's own proportions. A frame that did not match them would letterbox or crop
    /// every image put inside it, which is the one thing a frame must not do.
    static var aspect: CGFloat { 603.0 / 1311.0 }

    /// The bezel, as a fraction of the screen it surrounds rather than as a number of points.
    ///
    /// The site's mockup is a fixed 310-point body with 10 points of padding, and this frame is
    /// derived from whatever height the stage can spare — so the same 10 points here was 4.8% of
    /// the picture at the size the tour actually draws it, against the 3.4% the site draws the
    /// identical device at. A fixed border in one place and a derived one in the other is two
    /// devices, and the fat one is the one nobody drew. This is the site's own ratio: its padding
    /// over the 290-point screen it pads.
    static let bezel: CGFloat = 10.0 / 290.0

    /// Corner as a fraction of the body's width, and of the screen's — the site's 46 and 37 points
    /// against its 310-point body and 290-point screen.
    static let bodyCorner: CGFloat = 0.148
    static let screenCorner: CGFloat = 0.128

    /// The device's own colour, and the hairline of light along its edge.
    ///
    /// **Black, because that is what the front of an iPhone is.** The bezel around the display is
    /// the same black glass as the display, so face on the device is one black rectangle with a
    /// machined highlight around it, and the screen in it is a hole in that black rather than a
    /// picture in a frame. It used to be white at 18% fading to 5%, which over this near-black
    /// backdrop is not a device at all but a bright band, and a bright band is what the eye
    /// measures when it decides how thick a frame is, which is what was making this look like a
    /// mount. The two near-black greys it became were the right idea at half strength: a laptop lid
    /// has a bezel of its own colour, and a phone's does not.
    ///
    /// ``MacStageMetrics/lid`` has been black all along, so this is the two machines agreeing about
    /// what these devices look like rather than a detail the phone lost. Nothing goes with it
    /// either: the shape is described by ``rim``, which is the light along the outside edge and the
    /// same highlight the Mac has, and that was the only thing describing it in the first place.
    static let body = Color.black
    static let rim = LinearGradient(
        colors: [.white.opacity(0.30), .white.opacity(0.08)],
        startPoint: .top,
        endPoint: .bottom
    )
    static let rimWidth: CGFloat = 1

    /// The screen's height, given the box the whole device has to fit inside.
    ///
    /// Solved rather than measured in two passes, because the bezel is a fraction of the screen and
    /// the screen is the thing being solved for. Both limits — the box's height and its width —
    /// are linear in the screen's height once the bezel is written in terms of it, so each is a
    /// division and the tighter one wins. The floor keeps a zero-sized box, which is what the
    /// first layout pass offers, from being a division into something the geometry reader cannot
    /// draw.
    static func screenHeight(in box: CGSize) -> CGFloat {
        let byHeight = box.height / (1 + 2 * aspect * bezel)
        let byWidth = box.width / (aspect * (1 + 2 * bezel))
        return max(min(byHeight, byWidth), 1)
    }
}

/// The phone the tour holds up: one frame on every page, with only its screen changing.
///
/// The pages are about a single object, and a stage that is a bare glyph on one page and a card on
/// the next reads as five different screens rather than five views of one. So the frame is the
/// constant and the screen inside it is the variable — the shape is the app's shape from the first
/// page to the last, and each page's picture lands inside it.
///
/// **Sized at one, and moved by the stage.** This is the phone as it is when it is alone, and it is
/// the only size the drawing is ever built at: the first page wants it smaller, standing in front of
/// the Mac, and the stage scales this down to put it there (see ``OnboardingView/stageLayout(in:)``).
/// Scaling the drawing down to a size and holding it there is one phone; drawing it at the pair's
/// size and scaling it up to this one would be a phone rendered at 120% of itself for the rest of
/// the tour.
///
/// The proportions are the marketing site's own mockup, down to the bezel and the corner: that
/// picture of the app and this one are the same claim about what the app looks like, and two
/// devices with different corner radii would be two claims.
struct PhoneStage<Screen: View>: View {
    @ViewBuilder var screen: () -> Screen

    var body: some View {
        GeometryReader { proxy in
            // Height is the constraint on a phone and width almost never is — but a short, wide
            // window is exactly where a height-only sum runs off the edge, so both are asked.
            let screenHeight = PhoneStageMetrics.screenHeight(in: proxy.size)

            PhoneDrawing(screenWidth: screenHeight * PhoneStageMetrics.aspect) { screen() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The phone's body, bezel, screen and island, at a width the caller has already solved for.
///
/// Split out of ``PhoneStage`` so that drawing a phone and deciding how big it is are two jobs: the
/// stage solves one size for a box, and this draws at whatever size it is handed. Everything inside
/// is the site's mockup, drawn from the screen's width and nothing else, which is also what makes
/// the drawing safe to scale, because every part of it is a fraction of that one number.
struct PhoneDrawing<Screen: View>: View {
    /// The screen's own width. The bezel, the body and the corners are all fractions of it, so this
    /// is the one number the drawing needs.
    let screenWidth: CGFloat
    @ViewBuilder var screen: () -> Screen

    var body: some View {
        let screenHeight = screenWidth / PhoneStageMetrics.aspect
        let bezel = screenWidth * PhoneStageMetrics.bezel
        let bodyWidth = screenWidth + bezel * 2
        let bodyHeight = screenHeight + bezel * 2
        let body = RoundedRectangle(
            cornerRadius: bodyWidth * PhoneStageMetrics.bodyCorner,
            style: .continuous
        )

        body
            .fill(PhoneStageMetrics.body)
            .overlay {
                screen()
                    .frame(width: screenWidth, height: screenHeight)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: screenWidth * PhoneStageMetrics.screenCorner,
                            style: .continuous
                        )
                    )
                    // The island is part of the phone rather than part of the picture, so it is
                    // drawn here rather than expected in every screenshot. A screenshot of this
                    // app already has one — its own is black on a black backdrop — and the two
                    // land in the same place on the same device.
                    .overlay(alignment: .top) {
                        Capsule()
                            .fill(.black)
                            .frame(width: screenWidth * 0.30, height: screenHeight * 0.038)
                            .padding(.top, screenHeight * 0.019)
                    }
            }
            .frame(width: bodyWidth, height: bodyHeight)
            // The machined edge, drawn inside the body rather than around it so that the
            // highlight is the last thing on the device and not a ring floating off it. One
            // point, following the same light as the body it sits on.
            .overlay {
                body.strokeBorder(PhoneStageMetrics.rim, lineWidth: PhoneStageMetrics.rimWidth)
            }
            .shadow(color: .black.opacity(0.55), radius: 22, y: 10)
    }
}

// MARK: - Tablet frame

/// The iPad frame's numbers, matched to the site's phone mockup in method: every dimension is a
/// fraction of the screen width so the drawing stays in proportion at any size.
///
/// Dimensions are based on a portrait iPad Pro 11-inch (834×1194 points). The bezel is proportionally
/// thinner than the phone's — an iPad's front face has less glass around its display — and the corner
/// radius is more moderate. Everything else (black body, machined rim, same shadow) keeps the two
/// frames reading as the same family rather than as two unrelated shapes.
enum TabletStageMetrics {
    /// Portrait screenshot proportions for an 11-inch iPad Pro (834×1194 points).
    static var aspect: CGFloat { 834.0 / 1194.0 }

    /// Bezel as a fraction of the screen width. Thinner than the phone's 7/290 because an iPad's
    /// display sits closer to its edges.
    static let bezel: CGFloat = 10.0 / 834.0

    /// Body and screen corners as fractions of the body's width and screen's width respectively.
    /// Smaller than the phone's 0.148, matching the gentler radius of a real iPad.
    static let bodyCorner: CGFloat = 0.068
    static let screenCorner: CGFloat = 0.056

    static let body = Color.black

    /// The screen's height given the box the whole device has to fit inside.
    static func screenHeight(in box: CGSize) -> CGFloat {
        let byHeight = box.height / (1 + 2 * aspect * bezel)
        let byWidth = box.width / (aspect * (1 + 2 * bezel))
        return max(min(byHeight, byWidth), 1)
    }
}

/// The iPad's body, bezel and screen at a width the caller has already solved for.
///
/// Parallel to ``PhoneDrawing``: same construction logic, same rim treatment, same shadow, different
/// proportions. The tablet has no Dynamic Island so none is drawn here.
struct TabletDrawing<Screen: View>: View {
    let screenWidth: CGFloat
    @ViewBuilder var screen: () -> Screen

    var body: some View {
        let screenHeight = screenWidth / TabletStageMetrics.aspect
        let bezel = screenWidth * TabletStageMetrics.bezel
        let bodyWidth = screenWidth + bezel * 2
        let bodyHeight = screenHeight + bezel * 2
        let bodyShape = RoundedRectangle(
            cornerRadius: bodyWidth * TabletStageMetrics.bodyCorner,
            style: .continuous
        )

        bodyShape
            .fill(TabletStageMetrics.body)
            .overlay {
                screen()
                    .frame(width: screenWidth, height: screenHeight)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: screenWidth * TabletStageMetrics.screenCorner,
                            style: .continuous
                        )
                    )
            }
            .frame(width: bodyWidth, height: bodyHeight)
            .overlay {
                bodyShape.strokeBorder(PhoneStageMetrics.rim, lineWidth: PhoneStageMetrics.rimWidth)
            }
            .shadow(color: .black.opacity(0.55), radius: 22, y: 10)
    }
}

/// The iPad the regular-width tour holds up: one frame on every non-Mac page, with only its screen
/// changing. Parallel to ``PhoneStage`` but uses ``TabletStageMetrics`` for its proportions.
struct TabletStage<Screen: View>: View {
    @ViewBuilder var screen: () -> Screen

    var body: some View {
        GeometryReader { proxy in
            let screenHeight = TabletStageMetrics.screenHeight(in: proxy.size)
            TabletDrawing(screenWidth: screenHeight * TabletStageMetrics.aspect) { screen() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The Mac's frame, from the site's `.mac` mockup, which is the same drawing.
///
/// **Fractions rather than points, for the reason ``PhoneStageMetrics`` argues at length**: the
/// site draws these machines at a fixed size and this file derives them from whatever the stage can
/// spare, so a fixed border in one place and a derived one in the other is two machines. Every
/// number below is the site's ratio, and changing one means changing `styles.css` with it.
enum MacStageMetrics {
    /// The display's own proportions, 1512 by 982. A frame that did not match them would letterbox
    /// or crop the one picture it exists to hold, and the capture it holds is exactly this shape.
    static var aspect: CGFloat { 1512.0 / 982.0 }

    /// The lid's bezel, as a fraction of the display it surrounds.
    static let bezel: CGFloat = 0.017
    /// The lid's top corners, and its lower ones. The lower pair is much tighter, which is the
    /// shape rather than a detail: the lid is a panel, and only its top edge is a machined roll.
    static let lidCorner: CGFloat = 0.030
    static let lidLowerCorner: CGFloat = 0.009

    /// The base, as fractions of the lid it sits under and of its own height.
    static let baseHeight: CGFloat = 0.030
    /// Wider than the lid. This is the whole of why the two read as one machine rather than as a
    /// screen standing on a bar.
    static let baseOverhang: CGFloat = 1.055
    static let baseCorner: CGFloat = 0.36

    /// The camera housing, which every MacBook Pro since 2021 has.
    ///
    /// Part of the machine rather than part of the picture: a screenshot cannot contain it, because
    /// it is not something the display draws, it is something the display is missing. Drawn over
    /// whatever is in the screen, in the black of the housing.
    static let notchWidth: CGFloat = 0.092
    static let notchHeight: CGFloat = 0.026
    static let notchCorner: CGFloat = 0.013

    /// The scoop in the front edge, which is the one detail that says MacBook rather than laptop.
    static let scoopWidth: CGFloat = 0.15
    static let scoopHeight: CGFloat = 0.55

    /// The machines' own colours. The lid is black, because the lid of a MacBook is black glass and
    /// the bezel and the housing in it are the same black; that is the whole point of the notch,
    /// which is a cut in the display rather than a shape stuck onto it. The base is the site's two
    /// greys, and the rim is the phone's own, because it is the same machined edge.
    static let lid = Color.black
    static let baseTop = Color(red: 0.110, green: 0.110, blue: 0.122)
    static let baseBottom = Color(red: 0.043, green: 0.043, blue: 0.051)
    static let scoop = Color(red: 0.024, green: 0.024, blue: 0.027)
    static let hinge = LinearGradient(
        colors: [.clear, .white.opacity(0.20), .clear],
        startPoint: .leading,
        endPoint: .trailing
    )
}

/// The pair's own numbers, which are the site's `.stage` rules written as fractions of the Mac's
/// display — the same unit `styles.css` uses, for the same reason.
///
/// **The first page is about there being two apps**, so its stage is the pair and not a machine: a
/// laptop alone on the page that says "install this on your Mac" leaves the reader holding the half
/// of the product nobody is talking about. The arrangement is the marketing site's hero, down to
/// the overlap and the lift: the same two screenshots in the same two frames, because it is the
/// same claim about the product and two compositions would be two claims.
///
/// The fraction the phone is drawn at is not the true one. An honest 14-inch MacBook beside an
/// honest iPhone draws the phone at about half the width it is given here, and a screenshot nobody
/// can read is not a screenshot. It is the fraction that keeps both legible.
enum MacAndPhoneMetrics {
    /// The phone's screen, as a fraction of the Mac's display width.
    static let phoneScreen: CGFloat = 0.46

    /// How far the phone stands over the Mac's right-hand edge, as a fraction of the display width.
    /// This is the site's `-0.14`, and it is what makes the phone *in front of* the Mac rather than
    /// beside it.
    static let overlap: CGFloat = 0.14

    /// How much the Mac is lifted above the floor the phone stands on, as a fraction of the display
    /// width. The site's `margin-bottom` on the Mac, and the whole of why the pair reads as two
    /// objects on one surface rather than as one picture cropped twice.
    static let macLift: CGFloat = 0.035

    /// The pair's parts, named so that the solve for its size and the arithmetic that stands the
    /// phone in it cannot drift apart.
    ///
    /// This used to be an `HStack` with the Mac and the phone in it, and the parts were the
    /// expressions inside its two children. The phone cannot be a child of it any more: it has to
    /// be one drawing across the whole tour so that it can grow from the pair into the stage. So
    /// the `HStack` was written out as the arithmetic it always was, and these are the terms it
    /// comes to. Both readers are in ``OnboardingView/stageLayout(in:)`` now; the sum is here
    /// because the numbers are the pair's rather than the stage's.
    ///
    /// Every length is a multiple of the Mac's display width, which is the site's own unit.
    struct Parts {
        /// The Mac's widest part, which is its base.
        let macWidth: CGFloat
        /// The Mac's own height, and its height including the lift it stands on.
        let macHeight: CGFloat
        let macColumn: CGFloat
        /// The phone's body, over the screen it holds.
        let phoneWidth: CGFloat
        let phoneHeight: CGFloat
        /// What the two make together, which is what the box is fitted against.
        let width: CGFloat
        let height: CGFloat
    }

    static var parts: Parts {
        let mac = MacStageMetrics.self
        let phone = PhoneStageMetrics.self

        let lid = 1 + 2 * mac.bezel
        let phoneWidth = phoneScreen * (1 + 2 * phone.bezel)
        let phoneHeight = phoneScreen * (1 / phone.aspect + 2 * phone.bezel)
        // The bezel above and below the display, and the base under it. The lift is not part of the
        // machine and is not counted here: it is what the Mac stands on, not what it is.
        let macHeight = 1 / mac.aspect + 2 * mac.bezel + lid * mac.baseHeight

        return Parts(
            macWidth: lid * mac.baseOverhang,
            macHeight: macHeight,
            macColumn: macHeight + macLift,
            phoneWidth: phoneWidth,
            phoneHeight: phoneHeight,
            // The phone drawn *over* the Mac's edge, so the pair is narrower than its two parts by
            // the strip they share. This is the `HStack`'s negative spacing.
            width: lid * mac.baseOverhang + phoneWidth - overlap,
            // The taller of the two columns, because they stand on one floor. It is the phone: a
            // laptop is wide and a phone is nearly all screen.
            height: max(macHeight + macLift, phoneHeight)
        )
    }

    /// The display's height, given the box the pair has to fit inside.
    ///
    /// Solved rather than measured in two passes, for the reason
    /// ``PhoneStageMetrics/screenHeight(in:)`` gives, and by the same method: every dimension of
    /// both machines is linear in the display's height once every fraction is written in terms of
    /// it, so the width limit and the height limit are each one division and the tighter one wins.
    ///
    /// **Two limits that the Mac alone does not have.** The width now carries the phone across the
    /// Mac's right edge, and the height now has to clear the phone, which is the taller of the two
    /// — a phone standing on the same surface as a laptop, and a phone is nearly all screen.
    ///
    /// Everything here is written in units of the Mac's display *width*, which is the site's own
    /// unit: the display's height is the one term that has to be turned into it, and every other
    /// number is already a fraction of it. What the box then decides is the one scale both machines
    /// are drawn at, which is why the two limits are the pair's own width and height and nothing
    /// else.
    static func displayHeight(in box: CGSize) -> CGFloat {
        let parts = Self.parts

        // A display width is a display height times the aspect, so each limit is the box divided by
        // its own ratio: the aspect appears once, because both limits are measured in widths.
        let byHeight = box.height / (MacStageMetrics.aspect * parts.height)
        let byWidth = box.width / (MacStageMetrics.aspect * parts.width)
        return max(min(byHeight, byWidth), 1)
    }
}

/// The lid, the screen, the notch and the base, at a size the caller has already solved for.
///
/// **A second frame rather than a second screen for the first one.** The tour's pages are about
/// what the app does, and the one page that is about the Mac app has nothing to show until that
/// app has been installed: a phone frame with a Mac screenshot inside it would be the one drawing
/// in this file that says something untrue about the product. Its proportions come from the same
/// place ``PhoneDrawing``'s do, which is the site, so the two devices are one claim about what
/// these machines look like.
///
/// Drawn from a size rather than solving for one, for the reason ``PhoneDrawing`` is: the page that
/// holds it is solving one size for two machines (this one and the phone standing over it), so
/// neither may size itself, and a stage that held a Mac alone would be a ``GeometryReader`` with a
/// division in it rather than a drawing.
struct MacDrawing<Screen: View>: View {
    /// The display's own height. The bezel, the lid, the base and the notch are all fractions of
    /// it or of the display's width, which follows from this one number.
    let displayHeight: CGFloat
    @ViewBuilder var screen: () -> Screen

    var body: some View {
        let displayWidth = displayHeight * MacStageMetrics.aspect
        let bezel = displayWidth * MacStageMetrics.bezel
        let lidWidth = displayWidth + bezel * 2
        let lidHeight = displayHeight + bezel * 2
        let baseHeight = lidWidth * MacStageMetrics.baseHeight
        let lid = UnevenRoundedRectangle(
            topLeadingRadius: lidWidth * MacStageMetrics.lidCorner,
            bottomLeadingRadius: lidWidth * MacStageMetrics.lidLowerCorner,
            bottomTrailingRadius: lidWidth * MacStageMetrics.lidLowerCorner,
            topTrailingRadius: lidWidth * MacStageMetrics.lidCorner,
            style: .continuous
        )

        VStack(spacing: 0) {
            lid
                .fill(MacStageMetrics.lid)
                .overlay {
                    screen()
                        .frame(width: displayWidth, height: displayHeight)
                        // Concentric with the lid, which is the site's own `--screen-r`: the
                        // screen's corner is the lid's less the bezel that surrounds it, so
                        // the black between the two is the same width all the way round.
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: lidWidth * MacStageMetrics.lidCorner - bezel,
                                style: .continuous
                            )
                        )
                        .overlay(alignment: .top) {
                            notch(width: displayWidth, height: displayHeight)
                        }
                }
                .frame(width: lidWidth, height: lidHeight)
                // The machined edge, drawn inside the body rather than around it, the same way
                // and for the same reason the phone's is.
                .overlay {
                    lid.strokeBorder(PhoneStageMetrics.rim, lineWidth: PhoneStageMetrics.rimWidth)
                }

            base(width: lidWidth * MacStageMetrics.baseOverhang, height: baseHeight)
        }
        .shadow(color: .black.opacity(0.62), radius: 26, y: 16)
    }

    func notch(width: CGFloat, height: CGFloat) -> some View {
        let shape = UnevenRoundedRectangle(
            bottomLeadingRadius: height * MacStageMetrics.notchCorner,
            bottomTrailingRadius: height * MacStageMetrics.notchCorner,
            style: .continuous
        )

        // Pure black, and nothing drawn on it. It carried a hairline of white at 16% down its
        // inside edge, on the reasoning that the housing is a black shape on a black bezel and
        // needs an edge to read as a cut rather than as a smudge. That is not what a notch looks
        // like: it is a hole in the display, nothing catches the light inside it face on, and the
        // line made it read as a shape laid on top of the screen instead of missing from it.
        //
        // It is the phone's island's own treatment, which has never had an edge either. The two
        // are the same thing on the same kind of glass, so they are drawn the same way, and what
        // tells the notch apart from the menu bar behind it is the menu bar, which is a capture of
        // a real desktop and is never this black.
        return shape
            .fill(.black)
            .frame(width: width * MacStageMetrics.notchWidth, height: height * MacStageMetrics.notchHeight)
    }

    func base(width: CGFloat, height: CGFloat) -> some View {
        UnevenRoundedRectangle(
            bottomLeadingRadius: height * MacStageMetrics.baseCorner,
            bottomTrailingRadius: height * MacStageMetrics.baseCorner,
            style: .continuous
        )
        .fill(
            LinearGradient(
                colors: [MacStageMetrics.baseTop, MacStageMetrics.baseBottom],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .frame(width: width, height: height)
        // The lit hinge where the base meets the lid, so the two read as one machine rather than as
        // a screen standing on a bar.
        .overlay(alignment: .top) {
            Rectangle()
                .fill(MacStageMetrics.hinge)
                .frame(height: 1)
        }
        // The scoop in the front edge, centred and hung from the top of the base.
        .overlay(alignment: .top) {
            Capsule()
                .fill(MacStageMetrics.scoop)
                .frame(
                    width: width * MacStageMetrics.scoopWidth,
                    height: height * MacStageMetrics.scoopHeight
                )
        }
    }
}

// MARK: - The drawn notification
