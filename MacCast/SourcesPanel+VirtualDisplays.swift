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
    /// ``PlanCapability/virtualDisplays`` every tile is dimmed, badged and opens the paywall, and the
    /// "+" is the row that sells it. See ``VirtualDisplayManagementSupport``.
    @ViewBuilder
    var virtualDisplaysSection: some View {
        if model.hostSupportsVirtualDisplayManagement {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(String(localized: "Virtual Displays"))
                if managedVirtualDisplays.isEmpty {
                    // Nothing to show yet, so a small + and a line saying what one is, rather
                    // than a full-height row that is mostly empty.
                    HStack(spacing: 12) {
                        PlanLocked(capability: .virtualDisplays) {
                            addVirtualDisplayTile(height: 44)
                        }
                        Text("No virtual displays. Add one to give your iPhone a screen of its own on the Mac, the shape of this phone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    // The same row as the screens and windows: pictures, a + at the end, and a
                    // long press for the dots.
                    HStack(alignment: .top, spacing: Self.tileGap) {
                        Self.tileRow {
                            ForEach(managedVirtualDisplays) { descriptor in
                                PlanLocked(capability: .virtualDisplays) {
                                    previewTile(descriptor, fallbackIcon: "display", height: Self.packedTileHeight)
                                }
                            }
                        }
                        PlanLocked(capability: .virtualDisplays) {
                            addVirtualDisplayTile()
                        }
                    }
                }
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

    func removeVirtualDisplay(_ descriptor: CaptureSourceDescriptor, id: UInt32) {
        pendingVirtualDisplayRemovalIDs.insert(descriptor.id)
        model.send(.removeVirtualDisplay(displayID: id))
        Task {
            try? await Task.sleep(for: Self.virtualDisplayPendingTimeout)
            pendingVirtualDisplayRemovalIDs.remove(descriptor.id)
        }
    }

    /// One tap, one display, at a fixed phone-shaped landscape size, with no picker in front of it.
    /// See ``VirtualDisplaySizePreset``.
    func addVirtualDisplayTile(height: CGFloat = packedTileHeight) -> some View {
        let atLimit = managedVirtualDisplays.count >= VirtualDisplayManagementSupport.maximumManagedDisplayCount
        return addTile(label: String(localized: "Add a display"), busy: isAddingVirtualDisplay, disabled: atLimit, height: height) {
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
        }
    }
}
