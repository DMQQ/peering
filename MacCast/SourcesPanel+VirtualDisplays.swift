import MacCastKit
import RemoteCore
import SwiftUI
import UIKit

extension SourcesPanel {
    /// Every display this Mac made in software, and the one way to add or remove more of them.
    ///
    /// **Its own labelled group, apart from ``screensSection(_:)``.** A display made this way looks
    /// exactly like a real monitor everywhere else this panel draws one, and a phone with no way to
    /// tell them apart is a phone asking "is that real" of every tile it does not recognise. This
    /// heading is the answer: everything under it exists only in software, and nothing outside it
    /// does.
    ///
    /// **Every display here was asked for by a phone, and the plan pays for showing them.** There is
    /// no second kind: the Mac's own switch made one once, free on every plan, and it is gone, so
    /// what this group holds is what somebody tapped for. On a plan without
    /// ``PlanCapability/virtualDisplays`` every row is dimmed, badged and opens the paywall, and the
    /// "+" is the row that sells it. See ``VirtualDisplayManagementSupport``.
    @ViewBuilder
    var virtualDisplaysSection: some View {
        if model.hostSupportsVirtualDisplayManagement {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    SectionLabel("Virtual Displays")
                    Spacer()
                    PlanLocked(capability: .virtualDisplays, placement: .trailing) {
                        addVirtualDisplayButton
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(managedVirtualDisplays.enumerated()), id: \.element.id) { index, descriptor in
                        if index > 0 { Controls.divider }
                        PlanLocked(capability: .virtualDisplays, placement: .trailing) {
                            virtualDisplayRow(descriptor)
                        }
                    }
                }
                .rowSurface()
            }
            // The honest signal that a pending add or remove actually landed: the catalogue
            // changed shape. Clearing the spinners here rather than only on the timeout is what
            // makes the ordinary case feel instant instead of always taking the full seven
            // seconds.
            .onChange(of: managedVirtualDisplays.count) { _, _ in isAddingVirtualDisplay = false }
            .onChange(of: managedVirtualDisplays.map(\.id)) { _, ids in
                pendingVirtualDisplayRemovalIDs.formIntersection(ids)
            }
        }
    }

    /// The displays this feature may be asked to remove, in the catalogue's own order.
    var managedVirtualDisplays: [CaptureSourceDescriptor] {
        model.catalog?.displays.filter(\.isManagedVirtualDisplay) ?? []
    }

    /// Whether this phone's plan shows and adds virtual displays, asked once for the whole group.
    ///
    /// The question ``PlanLocked`` asks of each row, read here for the one thing a locked row has to
    /// do differently: leave out the controls it is not entitled to use.
    var includesVirtualDisplays: Bool {
        model.storeManager.access.includes(.virtualDisplays)
    }

    /// One row: tapping the picture or the name looks at that display, same as tapping any
    /// screen's tile.
    ///
    /// Drawn as itself whatever the plan, and gated by the caller rather than here, so this stays a
    /// drawing of a row. See ``virtualDisplaysSection``.
    func virtualDisplayRow(_ descriptor: CaptureSourceDescriptor) -> some View {
        let isLive = descriptor.id == model.activeSourceID
        let isPendingRemoval = pendingVirtualDisplayRemovalIDs.contains(descriptor.id)

        return HStack(spacing: 10) {
            Button {
                choose(descriptor)
            } label: {
                HStack(spacing: 10) {
                    // The same picture a physical screen's tile shows, at row height rather than
                    // tile height. A generic monitor glyph here was the other half of "why do
                    // virtual displays look different from real ones" — the icon never changed
                    // no matter what was actually on screen, so nothing here answered "is that
                    // one still showing my desktop" the way every other row in this panel does.
                    ZStack {
                        ColorPalette.surface
                        if let thumbnail = descriptor.thumbnail,
                           let image = thumbnails.image(for: descriptor.id, data: thumbnail.jpegData) {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "display")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 40, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(isLive ? ColorPalette.accent : ColorPalette.ink.opacity(0.18), lineWidth: isLive ? 1.5 : 1)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(descriptor.title)
                            .font(.subheadline.weight(isLive ? .semibold : .medium))
                            .foregroundStyle(isLive ? ColorPalette.accent : ColorPalette.ink)
                        if let subtitle = descriptor.subtitle {
                            Text(subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isPendingRemoval)
            .opacity(isPendingRemoval ? 0.5 : 1)

            // Not drawn on a plan that cannot use the display at all: they are part of the gated
            // control, and the badge lands in the room they would have taken.
            if includesVirtualDisplays {
                Button {
                    renameVirtualDisplayDraft = descriptor.title
                    renameVirtualDisplayTarget = descriptor
                } label: {
                    Image(systemName: "pencil.circle")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(isPendingRemoval)
                .accessibilityLabel("Rename \(descriptor.title)")

                Button {
                    guard case .display(let id) = descriptor.source else { return }
                    pendingVirtualDisplayRemovalIDs.insert(descriptor.id)
                    model.send(.removeVirtualDisplay(displayID: id))
                    Task {
                        try? await Task.sleep(for: Self.virtualDisplayPendingTimeout)
                        pendingVirtualDisplayRemovalIDs.remove(descriptor.id)
                    }
                } label: {
                    if isPendingRemoval {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 17, height: 17)
                    } else {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 17))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isPendingRemoval)
                .accessibilityLabel(isPendingRemoval ? "Removing \(descriptor.title)" : "Remove \(descriptor.title)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// One tap, one display, at a fixed phone-shaped landscape size — no picker in front of it.
    /// See ``VirtualDisplaySizePreset``.
    var addVirtualDisplayButton: some View {
        let atLimit = managedVirtualDisplays.count >= VirtualDisplayManagementSupport.maximumManagedDisplayCount
        let disabled = atLimit || isAddingVirtualDisplay
        return Button {
            isAddingVirtualDisplay = true
            model.send(.addVirtualDisplay(
                name: "",
                width: VirtualDisplaySizePreset.portraitWidth,
                height: VirtualDisplaySizePreset.portraitHeight,
                startLandscape: true
            ))
            Task {
                try? await Task.sleep(for: Self.virtualDisplayPendingTimeout)
                isAddingVirtualDisplay = false
            }
        } label: {
            if isAddingVirtualDisplay {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(atLimit ? Color.secondary : ColorPalette.accent)
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(atLimit ? "Already at the limit of \(VirtualDisplayManagementSupport.maximumManagedDisplayCount) added displays" : "Add a display")
        .accessibilityLabel(isAddingVirtualDisplay ? "Adding a display" : "Add a display")
    }
}
