import PeeringKit
import StoreKit
import SwiftUI
import UIKit

extension OnboardingView {
    var regularWidthBody: some View {
        ZStack {
            ColorPalette.backdrop.ignoresSafeArea()
            TopGlow()

            VStack(spacing: 0) {
                TabView(selection: $index) {
                    ForEach(Array(Self.pages.enumerated()), id: \.offset) { offset, page in
                        regularWidthPage(page, at: offset).tag(offset)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .overlay { regularWidthStage }

                indicator

                actions
                    .frame(maxWidth: 460)
            }
            .frame(maxWidth: 1180)

            if !showsPlans {
                SkipButton(action: skip)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }

    @ViewBuilder
    func regularWidthPage(_ page: Page, at offset: Int) -> some View {
        let here = offset == index
        let shown = here ? contentVisible : true

        if case .plans = page.content {
            regularWidthPlansPage(page, shown: shown, lit: here)
        } else {
            regularWidthDevicePage(page, shown: shown, lit: here)
        }
    }

    func regularWidthDevicePage(_ page: Page, shown: Bool, lit: Bool) -> some View {
        HStack(spacing: 56) {
            VStack(alignment: .leading, spacing: 22) {
                heading(page.title, lit: lit)
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 14)
                    .animation(motion(delay: 0.09), value: shown)

                Text(page.body)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 18)
                    .animation(motion(delay: 0.16), value: shown)

                if case .mac = page.device {
                    downloadLink
                        .opacity(shown ? 1 : 0)
                        .offset(y: shown ? 0 : 20)
                        .animation(motion(delay: 0.24), value: shown)
                }
            }
            .frame(maxWidth: 430, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .center)

            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 48)
        .padding(.top, 40)
        .padding(.bottom, 18)
    }

    func regularWidthPlansPage(_ page: Page, shown: Bool, lit: Bool) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            heading(page.title, lit: lit)
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 14)
                .animation(motion(delay: 0.09), value: shown)

            Text(page.body)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 18)
                .animation(motion(delay: 0.16), value: shown)

            plans
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            legalLinks
        }
        .frame(maxWidth: 680, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 48)
        .padding(.top, 36)
        .padding(.bottom, 8)
    }

    var regularWidthStage: some View {
        GeometryReader { proxy in
            if !isLast {
                let columnWidth = max((proxy.size.width - 152) / 2, 1)
                let box = CGSize(
                    width: min(columnWidth, 430),
                    height: min(max(proxy.size.height - 72, 1), 520)
                )
                let laid = stageLayout(in: box)

                ZStack {
                    if case .mac = Self.pages[index].device {
                        MacDrawing(displayHeight: laid.macDisplay ?? 1) { deviceScreen }
                            .offset(laid.macOffset)
                            .transition(.opacity)

                        PhoneStage { phoneScreen }
                            .scaleEffect(laid.phoneScale, anchor: .center)
                            .offset(laid.phoneOffset)
                            .transition(.opacity.animation(.easeOut(duration: 0.14)))
                    } else {
                        TabletStage { tabletScreen }
                            .transition(.opacity.animation(.easeOut(duration: 0.14)))
                    }
                }
                .frame(width: box.width, height: box.height)
                .overlay {
                    FloatingChips(chips: Self.pages[index].chips)
                        .id(index)
                        .transition(.opacity.animation(.easeOut(duration: 0.14)))
                }
                .position(x: proxy.size.width - 48 - columnWidth / 2, y: proxy.size.height / 2)
                .animation(Motion.settle, value: index)
            }
        }
        .allowsHitTesting(false)
    }
}
