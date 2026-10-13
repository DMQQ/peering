import PeeringKit
import SwiftUI

extension View {
    /// Shows the current release once. It is recorded as seen the moment it appears, not on the button: a swipe down or a relaunch mid-sheet must not bring it back.
    func presentsWhatsNew() -> some View {
        modifier(WhatsNewPresenter())
    }
}

private struct WhatsNewPresenter: ViewModifier {
    @AppStorage(PreferenceKeys.lastSeenWhatsNew) private var lastSeen = ""
    @AppStorage(PreferenceKeys.hasSeenWelcome) private var hasSeenWelcome = false
    @State private var release: WhatsNewRelease?

    func body(content: Content) -> some View {
        content
            .task {
                let current = WhatsNewRelease.current
                switch WhatsNewPolicy.decide(
                    currentRelease: current?.id,
                    lastSeenRelease: lastSeen.isEmpty ? nil : lastSeen,
                    hasSeenWelcome: hasSeenWelcome
                ) {
                case .show:
                    // Let the landing screen settle so the sheet does not race the first layout.
                    try? await Task.sleep(for: .seconds(1))
                    lastSeen = current?.id ?? ""
                    release = current
                case .recordWithoutShowing:
                    lastSeen = current?.id ?? ""
                case .nothing:
                    break
                }
            }
            .sheet(item: Binding(get: { release.map(Presented.init) }, set: { if $0 == nil { release = nil } })) { presented in
                WhatsNewSheet(release: presented.release) { release = nil }
            }
    }

    private struct Presented: Identifiable {
        let release: WhatsNewRelease
        var id: String { release.id }
    }
}
