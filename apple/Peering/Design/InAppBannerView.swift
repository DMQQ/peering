import RemoteCore
import SwiftUI
import UIKit

struct InAppBannerView: View {
    var banner: InAppBanner

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: CGFloat = 0

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            if let item = banner.current {
                card(item)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .offset(y: rubber(drag))
                    .transition(reduceMotion ? AnyTransition.opacity : AnyTransition(LiquidDrop()))
                    .id(item.id)
            }
        }
    }

    /// Pulling down stretches with resistance; pulling up follows the finger.
    private func rubber(_ value: CGFloat) -> CGFloat {
        value > 0 ? 24 * (1 - exp(-value / 60)) : value
    }

    private func card(_ item: InAppBannerItem) -> some View {
        let expanded = banner.isExpanded
        let radius: CGFloat = expanded ? 30 : 28
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return VStack(alignment: .leading, spacing: 12) {
            header(item, expanded: expanded)
            if expanded {
                if let body = item.body, !body.isEmpty {
                    Text(body)
                        .font(.system(size: 12.5, design: item.asksApproval ? .monospaced : .default))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(item.asksApproval ? 6 : 8)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .transition(.blurReplace)
                }
                actions(item)
                    .transition(.blurReplace)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ColorPalette.backdrop.opacity(0.97), in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
        .contentShape(shape)
        .scaleEffect(drag > 0 ? 1 + min(drag, 80) / 1400 : 1, anchor: .top)
        .animation(InAppBanner.reshape, value: expanded)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { banner.cardFrame = $0 }
        // The card moves with the finger, so a local-space drag shrinks as it follows and the card oscillates.
        .simultaneousGesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .global)
                .onChanged { drag = $0.translation.height }
                .onEnded { value in
                    let height = value.translation.height
                    let predicted = value.predictedEndTranslation.height
                    withAnimation(InAppBanner.reshape) { drag = 0 }
                    if height < -14 || predicted < -60 {
                        banner.dismiss()
                    } else if height > 14 || predicted > 60 {
                        banner.setExpanded(true)
                    } else {
                        banner.schedule()
                    }
                }
        )
        .sensoryFeedback(item.needsYou ? .warning : .success, trigger: item.id)
        .sensoryFeedback(.impact(flexibility: .soft), trigger: expanded)
    }

    private func header(_ item: InAppBannerItem, expanded: Bool) -> some View {
        HStack(spacing: 11) {
            Image(systemName: item.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(item.needsYou ? ColorPalette.caution : ColorPalette.ink)
                .symbolEffect(.bounce.up, options: .repeat(2), value: item.id)
                .frame(width: 38, height: 38)
                .background(.white.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(ColorPalette.ink)
                    .lineLimit(1)
                Text(item.summary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(expanded ? 3 : 1)
            }
            Spacer(minLength: 4)
            Button {
                banner.setExpanded(!expanded)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.08), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Collapse" : "Expand")
        }
        .contentShape(Rectangle())
        .onTapGesture { banner.setExpanded(!expanded) }
    }

    @ViewBuilder
    private func actions(_ item: InAppBannerItem) -> some View {
        if item.asksApproval, item.options.isEmpty {
            HStack(spacing: 10) {
                pill("Deny", filled: false) { banner.answer(.deny) }
                pill("Allow", filled: true) { banner.answer(.allow) }
            }
        } else if item.asksApproval {
            VStack(spacing: 8) {
                ForEach(item.options, id: \.self) { label in
                    pill(LocalizedStringKey(label), filled: false) { banner.answer(.choose([label])) }
                }
            }
        } else {
            HStack(spacing: 10) {
                pill("Dismiss", filled: false) { banner.dismiss() }
                if item.target?.opensScreen == true {
                    pill(item.openLabel, filled: true) { banner.open() }
                }
            }
        }
    }

    private func pill(_ label: LocalizedStringKey, filled: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(label)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(filled ? ColorPalette.onInk : .white)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background {
                    if filled {
                        Capsule().fill(ColorPalette.ink)
                    } else {
                        Capsule().fill(.white.opacity(0.12))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(SpringPressStyle())
    }
}

private struct SpringPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.5), value: configuration.isPressed)
    }
}
