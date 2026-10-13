import PeeringKit
import RemoteCore
import SwiftUI
import UIKit

extension SourcesPanel {
    /// Its own labelled group: a virtual display looks exactly like a real monitor elsewhere in this panel, and this heading says everything under it exists only in software.
    /// Every display here was asked for by a phone, and the plan pays for showing them: on a plan without `virtualDisplays` every tile is dimmed, badged and opens the paywall. See ``VirtualDisplayManagementSupport``.
    @ViewBuilder
    var virtualDisplaysSection: some View {
        if model.hostSupportsVirtualDisplayManagement {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(String(localized: "Virtual Displays"))
                if managedVirtualDisplays.isEmpty {
                    // Nothing to show yet: a small + and a line, not a mostly empty full-height row.
                    HStack(spacing: 12) {
                        addVirtualDisplayTile(height: 44)
                        Text("No virtual displays. Add one to give your iPhone a screen of its own on the Mac, the shape of this phone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    HStack(alignment: .top, spacing: Self.tileGap) {
                        Self.tileRow {
                            ForEach(managedVirtualDisplays) { descriptor in
                                previewTile(descriptor, fallbackIcon: "display", height: Self.packedTileHeight)
                            }
                        }
                        addVirtualDisplayTile()
                    }
                }
            }
            // The signal that a pending add or remove landed is the catalogue changing shape; clearing the spinners here makes the ordinary case instant instead of waiting out the seven seconds.
            .onChange(of: managedVirtualDisplays.count) { _, _ in isAddingVirtualDisplay = false }
            .onChange(of: managedVirtualDisplays.map(\.id)) { _, ids in
                pendingVirtualDisplayRemovalIDs.formIntersection(ids)
            }
        }
    }

    var managedVirtualDisplays: [CaptureSourceDescriptor] {
        model.catalog?.displays.filter(\.isManagedVirtualDisplay) ?? []
    }

    func removeVirtualDisplay(_ descriptor: CaptureSourceDescriptor, id: UInt32) {
        pendingVirtualDisplayRemovalIDs.insert(descriptor.id)
        model.send(.removeVirtualDisplay(displayID: id))
        Task {
            try? await Task.sleep(for: Self.virtualDisplayPendingTimeout)
            pendingVirtualDisplayRemovalIDs.remove(descriptor.id)
        }
    }

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
