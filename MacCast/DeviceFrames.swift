import MacCastKit
import StoreKit
import SwiftUI
import UIKit

enum PhoneStageMetrics {
    static var aspect: CGFloat { 603.0 / 1311.0 }

    /// A fraction of the screen, matching the site's ratio (10 over 290 points). A fixed border here rendered thicker than the site's identical device.
    static let bezel: CGFloat = 10.0 / 290.0

    /// The site's 46 and 37 points over its 310 and 290 point body and screen.
    static let bodyCorner: CGFloat = 0.148
    static let screenCorner: CGFloat = 0.128

    /// Black, as the front of an iPhone is: the screen reads as a hole in the black glass. A bright white band here read as a mount. Matches ``MacStageMetrics/lid``.
    static let body = Color.black
    static let rim = LinearGradient(
        colors: [.white.opacity(0.30), .white.opacity(0.08)],
        startPoint: .top,
        endPoint: .bottom
    )
    static let rimWidth: CGFloat = 1

    /// Solved in closed form: both limits are linear in screen height once the bezel is a fraction of it. The floor guards the zero-sized box of the first layout pass.
    static func screenHeight(in box: CGSize) -> CGFloat {
        let byHeight = box.height / (1 + 2 * aspect * bezel)
        let byWidth = box.width / (aspect * (1 + 2 * bezel))
        return max(min(byHeight, byWidth), 1)
    }
}

/// The one phone the tour holds up, built only at size one and scaled by the stage (see ``OnboardingView/stageLayout(in:)``), so it is never drawn small and scaled up. Proportions are the marketing site's mockup.
struct PhoneStage<Screen: View>: View {
    @ViewBuilder var screen: () -> Screen

    var body: some View {
        GeometryReader { proxy in
            // Both height and width are asked: a short, wide window runs off the edge on a height-only sum.
            let screenHeight = PhoneStageMetrics.screenHeight(in: proxy.size)

            PhoneDrawing(screenWidth: screenHeight * PhoneStageMetrics.aspect) { screen() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct PhoneDrawing<Screen: View>: View {
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
                    // The island is part of the phone, drawn here rather than expected in every screenshot.
                    .overlay(alignment: .top) {
                        Capsule()
                            .fill(.black)
                            .frame(width: screenWidth * 0.30, height: screenHeight * 0.038)
                            .padding(.top, screenHeight * 0.019)
                    }
            }
            .frame(width: bodyWidth, height: bodyHeight)
            .overlay {
                body.strokeBorder(PhoneStageMetrics.rim, lineWidth: PhoneStageMetrics.rimWidth)
            }
            .shadow(color: .black.opacity(0.55), radius: 22, y: 10)
    }
}

// MARK: - Tablet frame

/// Matched to the site's phone mockup in method: fractions of screen width. Based on a portrait iPad Pro 11-inch (834x1194 points), with a thinner bezel and gentler corners.
enum TabletStageMetrics {
    static var aspect: CGFloat { 834.0 / 1194.0 }

    static let bezel: CGFloat = 10.0 / 834.0

    static let bodyCorner: CGFloat = 0.068
    static let screenCorner: CGFloat = 0.056

    static let body = Color.black

    static func screenHeight(in box: CGSize) -> CGFloat {
        let byHeight = box.height / (1 + 2 * aspect * bezel)
        let byWidth = box.width / (aspect * (1 + 2 * bezel))
        return max(min(byHeight, byWidth), 1)
    }
}

/// The tablet has no Dynamic Island, so none is drawn.
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

/// The Mac's frame from the site's `.mac` mockup. Fractions, not points, for the reason ``PhoneStageMetrics`` gives; changing one means changing `styles.css`.
enum MacStageMetrics {
    /// The display's proportions, 1512 by 982, the shape of the capture it holds.
    static var aspect: CGFloat { 1512.0 / 982.0 }

    static let bezel: CGFloat = 0.017
    /// The lower corners are much tighter: only the lid's top edge is a machined roll.
    static let lidCorner: CGFloat = 0.030
    static let lidLowerCorner: CGFloat = 0.009

    static let baseHeight: CGFloat = 0.030
    static let baseOverhang: CGFloat = 1.055
    static let baseCorner: CGFloat = 0.36

    /// The camera housing is part of the machine, not the picture: a screenshot cannot contain it. Drawn over the screen in black.
    static let notchWidth: CGFloat = 0.092
    static let notchHeight: CGFloat = 0.026
    static let notchCorner: CGFloat = 0.013

    static let scoopWidth: CGFloat = 0.15
    static let scoopHeight: CGFloat = 0.55

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

/// The pair's numbers, the site's `.stage` rules as fractions of the Mac's display width. The phone's fraction is deliberately larger than true scale (about double) so the screenshot stays legible.
enum MacAndPhoneMetrics {
    static let phoneScreen: CGFloat = 0.46

    /// The site's -0.14: puts the phone in front of the Mac, not beside it.
    static let overlap: CGFloat = 0.14

    /// The site's `margin-bottom` on the Mac: why the pair reads as two objects on one surface.
    static let macLift: CGFloat = 0.035

    struct Parts {
        let macWidth: CGFloat
        let macHeight: CGFloat
        let macColumn: CGFloat
        let phoneWidth: CGFloat
        let phoneHeight: CGFloat
        let width: CGFloat
        let height: CGFloat
    }

    static var parts: Parts {
        let mac = MacStageMetrics.self
        let phone = PhoneStageMetrics.self

        let lid = 1 + 2 * mac.bezel
        let phoneWidth = phoneScreen * (1 + 2 * phone.bezel)
        let phoneHeight = phoneScreen * (1 / phone.aspect + 2 * phone.bezel)
        // The lift is not part of the machine and is not counted here.
        let macHeight = 1 / mac.aspect + 2 * mac.bezel + lid * mac.baseHeight

        return Parts(
            macWidth: lid * mac.baseOverhang,
            macHeight: macHeight,
            macColumn: macHeight + macLift,
            phoneWidth: phoneWidth,
            phoneHeight: phoneHeight,
            // The phone is drawn over the Mac's edge, so the pair is narrower than its parts by the shared strip.
            width: lid * mac.baseOverhang + phoneWidth - overlap,
            height: max(macHeight + macLift, phoneHeight)
        )
    }

    /// Solved in closed form as ``PhoneStageMetrics/screenHeight(in:)`` is. The width limit carries the phone across the Mac's right edge and the height limit must clear the phone, the taller of the two.
    static func displayHeight(in box: CGSize) -> CGFloat {
        let parts = Self.parts

        let byHeight = box.height / (MacStageMetrics.aspect * parts.height)
        let byWidth = box.width / (MacStageMetrics.aspect * parts.width)
        return max(min(byHeight, byWidth), 1)
    }
}

/// A second frame, not a Mac screenshot inside the phone frame, which would say something untrue about the product. Drawn from a size because the page solves one size for both machines.
struct MacDrawing<Screen: View>: View {
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
                        // Concentric with the lid (the site's screen-r): the screen corner is the lid's less the bezel.
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

        // Pure black with nothing drawn on it: a hairline made the notch read as a shape laid on the screen rather than missing from it. Same as the phone's island.
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
        .overlay(alignment: .top) {
            Rectangle()
                .fill(MacStageMetrics.hinge)
                .frame(height: 1)
        }
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
