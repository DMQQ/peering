import PeeringKit
import SwiftUI

/// The hub on a sideways phone or a wide iPad: the list on the left, whatever it opened on the right. Shares the remote screen's route with the pushed layout, so a rotation keeps the selection.
struct HubSplitView: View {
    @Binding var route: [RemoteRoute]

    static let sidebarWidth: CGFloat = 360

    private var steps: Binding<[TerminalFlowStep]> {
        Binding(
            get: {
                route.compactMap {
                    if case .step(let step) = $0 { step } else { nil }
                }
            },
            set: { route = [.hub] + $0.map(RemoteRoute.step) }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            NavigationStack {
                TerminalPanel(route: $route, picksForPane: true)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                route = []
                            } label: {
                                Image(systemName: "chevron.backward")
                            }
                            .accessibilityLabel(String(localized: "Back to the screen"))
                        }
                    }
            }
            .environment(\.horizontalSizeClass, .compact)
            .frame(width: Self.sidebarWidth)

            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(width: 1)
                .ignoresSafeArea()

            NavigationStack(path: steps) {
                HubDetailPlaceholder()
                    .navigationDestination(for: TerminalFlowStep.self) { step in
                        TerminalPanel(route: $route, step: step)
                    }
            }
        }
        .background(ColorPalette.backdrop.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}

/// The right pane before anything is picked.
private struct HubDetailPlaceholder: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
            Text(String(localized: "Nothing open"))
                .font(.headline)
                .foregroundStyle(ColorPalette.ink)
            Text(String(localized: "Pick a chat, a terminal or a file on the left."))
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ColorPalette.backdrop.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}
