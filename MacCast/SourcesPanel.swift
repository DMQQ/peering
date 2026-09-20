import RemoteCore
import SwiftUI

/// What the Mac can be made to share, as a floating panel.
///
/// The same list the sheet used to hold, rebuilt for a panel instead of a `List`. A `List` brings
/// its own backgrounds, separators and inset behaviour, none of which survive being put on top of
/// live video inside a sheet of glass — and the panel was already the shape every other control
/// on this screen uses. Search stays: a Mac with twenty running applications and a hundred
/// installed ones needs it more here than it did full-screen, not less.
struct SourcesPanel: View {
    @Environment(SessionModel.self) private var model

    @Binding var chromeFrames: [ChromeRegion: CGRect]

    /// Called once the user has picked a source or opened an application, so the caller can put the
    /// panel away — see the setting it consults.
    var onSelect: () -> Void = {}

    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchField

            if let catalog = model.catalog, !catalog.all.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        section("Displays", catalog.displays, fallbackIcon: "display")
                        section("Applications", catalog.applications, fallbackIcon: "app")
                        section("Windows", catalog.windows, fallbackIcon: "macwindow")
                        installedSection
                    }
                }
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "rectangle.on.rectangle.slash")
                        .foregroundStyle(.secondary)
                    Text("The Mac has not sent its list of displays and windows yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
            }
        }
        .padding(10)
        .glassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 10)
        .reportChromeFrame(.panel, into: $chromeFrames)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Find a display, application or window", text: $query)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(ColorPalette.surface, in: Capsule())
    }

    @ViewBuilder
    private func section(
        _ title: String,
        _ descriptors: [CaptureSourceDescriptor],
        fallbackIcon: String
    ) -> some View {
        let matches = filtered(descriptors)
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(title)
                ForEach(matches) { descriptor in
                    Button {
                        model.selectSource(descriptor)
                        onSelect()
                    } label: {
                        row(descriptor, fallbackIcon: fallbackIcon)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var installedSection: some View {
        let installed = filteredInstalled
        if !installed.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Installed on your Mac")
                ForEach(installed) { application in
                    Button {
                        model.launchApplication(application)
                        onSelect()
                    } label: {
                        HStack(spacing: 10) {
                            ApplicationIcon(data: application.iconPNGData, fallback: "app.dashed")
                            Text(application.title)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text("Open")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(ColorPalette.accent)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .rowSurface()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Text("Not running yet. Choosing one opens it on the Mac.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ source: CaptureSourceDescriptor, fallbackIcon: String) -> some View {
        HStack(spacing: 10) {
            ApplicationIcon(data: source.iconPNGData, fallback: fallbackIcon)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let subtitle = source.subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if source.id == model.activeSourceID {
                // A checkmark and nothing else: tapping a row switches to it immediately, so a
                // chevron promising another screen would be a lie.
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(ColorPalette.accent)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .rowSurface()
        .contentShape(Rectangle())
    }

    private var filteredInstalled: [InstalledApplicationDescriptor] {
        let applications = model.catalog?.installedApplicationsNotRunning ?? []
        guard !query.isEmpty else { return applications }
        return applications.filter { $0.title.localizedStandardContains(query) }
    }

    private func filtered(_ sources: [CaptureSourceDescriptor]) -> [CaptureSourceDescriptor] {
        guard !query.isEmpty else { return sources }
        return sources.filter {
            $0.title.localizedStandardContains(query)
                || ($0.subtitle?.localizedStandardContains(query) ?? false)
        }
    }
}
