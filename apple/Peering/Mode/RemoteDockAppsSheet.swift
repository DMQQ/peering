import PeeringKit
import RemoteCore
import SwiftUI

/// Every app on the Mac, for the trackpad: pinned ones on top, then what is running, then the rest installed. A tap brings the app forward on the Mac; a long press pins or unpins it.
struct RemoteDockAppsSheet: View {
    @Environment(SessionModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let hostID: String

    @State private var favouritesVersion = 0

    private struct Entry: Identifiable {
        let id: String
        let bundleIdentifier: String?
        let title: String
        let icon: Data?
    }

    private static let columns = [GridItem(.adaptive(minimum: 72, maximum: 90), spacing: 8, alignment: .top)]

    var body: some View {
        let favourites = ApplicationFavourites(hostID: hostID)
        let sections = sections(favourites: favourites)
        ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    TabScreenHeader(String(localized: "Apps"), detail: String(localized: "Press and hold an app to add it to Favourites."))
                    group(String(localized: "Favourites"), sections.favourites, favourites: favourites)
                    group(String(localized: "Running"), sections.running, favourites: favourites)
                    group(String(localized: "Installed on your Mac"), sections.installed, favourites: favourites)
                }
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 24)
                .id(favouritesVersion)
        }
        .background(ColorPalette.backdrop.ignoresSafeArea())
    }

    private func sections(favourites: ApplicationFavourites) -> ApplicationSections<Entry> {
        let catalog = model.catalog
        let running = (catalog?.applications ?? []).map {
            Entry(id: "running.\($0.id)", bundleIdentifier: $0.bundleIdentifier, title: $0.title, icon: $0.iconPNGData)
        }
        let installed = (catalog?.installedApplications ?? []).map {
            Entry(id: "installed.\($0.id)", bundleIdentifier: $0.bundleIdentifier, title: $0.title, icon: $0.iconPNGData)
        }
        return ApplicationSections(
            favourites: favourites.bundleIdentifiers,
            running: running,
            installed: installed,
            bundleIdentifier: \.bundleIdentifier
        )
    }

    @ViewBuilder
    private func group(_ title: String, _ entries: [Entry], favourites: ApplicationFavourites) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(title)
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 16) {
                    ForEach(entries) { entry in
                        cell(entry, favourites: favourites)
                    }
                }
            }
        }
    }

    private func cell(_ entry: Entry, favourites: ApplicationFavourites) -> some View {
        Button {
            if let bundle = entry.bundleIdentifier {
                model.send(.launchApplication(bundleIdentifier: bundle))
            }
            dismiss()
        } label: {
            VStack(spacing: 6) {
                ApplicationIcon(data: entry.icon, fallback: "app", size: 64, showsTile: false)
                Text(entry.title)
                    .font(.caption)
                    .foregroundStyle(ColorPalette.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(RailButtonStyle(scale: 0.92, haptic: true))
        .contextMenu {
            if let bundle = entry.bundleIdentifier {
                let pinned = favourites.contains(bundle)
                Button(
                    pinned ? String(localized: "Remove from Favourites") : String(localized: "Add to Favourites"),
                    systemImage: pinned ? "star.slash" : "star"
                ) {
                    favourites.toggle(bundle)
                    favouritesVersion += 1
                }
            }
        }
    }
}
