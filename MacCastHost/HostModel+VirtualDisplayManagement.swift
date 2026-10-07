import CoreGraphics
import Foundation
import MacCastKit
import RemoteCore

// MARK: - Virtual display management (phone-requested)

/// Session-scoped: these go when the client that asked goes, and when the host stops.
extension HostModel {
    /// Clamp for each side. Guards against absurd requests; VirtualDisplay itself floors at 2.
    static let minimumVirtualDisplaySide = 200
    static let maximumVirtualDisplaySide = 3000
    static let maximumVirtualDisplayNameLength = 80

    /// Failures are logged, not reported back: a RemoteCommand has no reply shape.
    func addVirtualDisplay(name: String, width: Int, height: Int, startLandscape: Bool) {
        guard !isMakingVirtualDisplay, !isTearingDownVirtualDisplays else { return }
        discardDepartedManagedVirtualDisplays()
        guard canShowVirtualDisplay else {
            record(
                "Could not add a display: this Mac's system software does not have the virtual display API.",
                level: .failure
            )
            return
        }
        guard managedVirtualDisplays.count < VirtualDisplayManagementSupport.maximumManagedDisplayCount else {
            record(
                """
                Could not add a display: already at the limit of \
                \(VirtualDisplayManagementSupport.maximumManagedDisplayCount) added displays.
                """,
                level: .failure
            )
            return
        }

        isMakingVirtualDisplay = true
        defer { isMakingVirtualDisplay = false }
        let creationGeneration = virtualDisplayCreationGeneration

        let serial = nextManagedVirtualDisplaySerial
        nextManagedVirtualDisplaySerial += 1
        let requestedName = String(
            name.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(Self.maximumVirtualDisplayNameLength)
        )
        let displayName = requestedName.isEmpty ? "Peering Display \(serial)" : requestedName
        let size = CGSize(
            width: min(max(width, Self.minimumVirtualDisplaySide), Self.maximumVirtualDisplaySide),
            height: min(max(height, Self.minimumVirtualDisplaySide), Self.maximumVirtualDisplaySide)
        )

        do {
            let display = try VirtualDisplay(
                size: size,
                name: displayName,
                startLandscape: startLandscape,
                serialNumber: serial,
                productID: 0x5044 &+ serial,
                isPhoneManaged: true
            )
            guard creationGeneration == virtualDisplayCreationGeneration else {
                _ = display.remove()
                return
            }
            managedVirtualDisplays.append(display)
            // The private API resets every virtual panel to 800×600 when another one is created.
            // Reassert the chosen mode for the ones already alive.
            for managed in managedVirtualDisplays { _ = managed.restoreCurrentMode() }
            guard creationGeneration == virtualDisplayCreationGeneration,
                  !isTearingDownVirtualDisplays,
                  managedVirtualDisplays.contains(where: { $0 === display })
            else { return }
            if case .display(let id) = capturingSource,
               virtualDisplayInstance(for: id) != nil {
                applyCaptureSource(.display(id))
            }
            record("Display \u{201C}\(displayName)\u{201D} added \u{00B7} \(display.displayID)")
            coordinator?.refreshCatalog()
            confirmManagedDisplayThroughCatalogue(display)
        } catch {
            Analytics.failed(error, in: .display)
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            record("Could not add a display: \(message)", level: .failure)
        }
    }

    func renameVirtualDisplay(displayID: CGDirectDisplayID, name: String) {
        let cleaned = String(
            name.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(Self.maximumVirtualDisplayNameLength)
        )
        guard !isTearingDownVirtualDisplays,
              !cleaned.isEmpty,
              managedVirtualDisplays.contains(where: { $0.displayID == displayID })
        else { return }
        VirtualDisplay.rename(displayID, to: cleaned)
        coordinator?.refreshCatalog()
    }

    /// If this is the live capture, the stream moves to another display first so removal cannot strand the client on black.
    @discardableResult
    func removeVirtualDisplay(displayID: CGDirectDisplayID) async -> Bool {
        guard !isMakingVirtualDisplay,
              !isTearingDownVirtualDisplays,
              managedVirtualDisplays.contains(where: { $0.displayID == displayID })
        else {
            return false
        }
        isMakingVirtualDisplay = true
        defer { isMakingVirtualDisplay = false }

        if capturingSource == .display(displayID), let coordinator {
            guard let fallbackID = VirtualDisplay.activeDisplayIDs().first(where: { $0 != displayID }) else {
                record("Could not remove the display: there is no other display to show", level: .failure)
                return false
            }
            do {
                try await coordinator.switchSource(.display(fallbackID))
            } catch {
                Analytics.failed(error, in: .display)
                let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                record("Could not move the picture before removing the display: \(message)", level: .failure)
                return false
            }
        }

        guard let index = managedVirtualDisplays.firstIndex(where: { $0.displayID == displayID }) else {
            return false
        }
        guard managedVirtualDisplays[index].remove() else {
            record("A display did not go away when it was removed", level: .failure)
            return false
        }
        managedVirtualDisplays.remove(at: index)
        coordinator?.refreshCatalog()
        return true
    }

    /// The ScreenCaptureKit catalogue can lag behind the window server. Retry, and do not leave an
    /// invisible display consuming one of the slots.
    func confirmManagedDisplayThroughCatalogue(_ display: VirtualDisplay) {
        let id = display.displayID
        Task { @MainActor [weak self] in
            for _ in 0..<12 {
                guard let self,
                      self.managedVirtualDisplays.contains(where: { $0.displayID == id })
                else { return }
                if self.catalog?.descriptor(for: .display(id)) != nil { return }
                self.coordinator?.refreshCatalog()
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard let self,
                  let index = self.managedVirtualDisplays.firstIndex(where: { $0.displayID == id })
            else { return }
            self.record("Added display is not offered to the phone; removing it", level: .failure)
            if self.managedVirtualDisplays[index].remove() {
                self.managedVirtualDisplays.remove(at: index)
                self.coordinator?.refreshCatalog()
            }
        }
    }

    func removeAllManagedVirtualDisplays() {
        guard !managedVirtualDisplays.isEmpty else { return }
        managedVirtualDisplays = managedVirtualDisplays.filter { display in
            let removed = display.remove()
            if !removed {
                record("A display is still leaving the screen; its removal will be retried", level: .failure)
            }
            return !removed
        }
    }

    /// Clears wrappers kept after a timed-out removal, before the add limit is enforced so a gone display cannot hold a slot.
    func discardDepartedManagedVirtualDisplays() {
        let active = Set(VirtualDisplay.activeDisplayIDs())
        managedVirtualDisplays.removeAll { display in
            guard !active.contains(display.displayID) else { return false }
            _ = display.remove()
            return true
        }
    }
}
