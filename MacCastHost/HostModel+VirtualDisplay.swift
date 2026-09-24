import Foundation
import RemoteCore

// MARK: - Virtual display

extension HostModel {
    static let virtualDisplayKey = "hostVirtualDisplay"

    /// Whether this Mac's system software has the API at all.
    ///
    /// Read by the row so the switch is offered as off-and-unavailable rather than thrown and
    /// failing, and by ``HostModel/start()`` so a Mac that never had it does not try at every
    /// launch.
    var canShowVirtualDisplay: Bool { VirtualDisplay.isAvailable }

    /// What the virtual display is, which is also the size the row promises.
    var virtualDisplaySize: String {
        "\(Int(VirtualDisplay.phoneShaped.width))×\(Int(VirtualDisplay.phoneShaped.height))"
    }

    /// Turns the phone-shaped display on or off, at the user's request.
    ///
    /// Synchronous, and deliberately: the row's switch has to end up where the display actually is,
    /// not where it was asked to be. The only thing slow enough to notice is the wait for the
    /// window server to take the display, bounded at three seconds by ``VirtualDisplay``. The one
    /// part that is not synchronous is confirming a display this process cannot see, which asks the
    /// catalogue rather than guess; see ``confirmThroughCatalogue(_:)``.
    func setVirtualDisplay(_ wanted: Bool) {
        guard wanted != virtualDisplayEnabled, !isMakingVirtualDisplay else { return }

        guard wanted else {
            // The switch stays on if the display would not leave, and the row says why: a switch
            // that reads off over a monitor still on screen is the one lie this row exists to make
            // impossible, and it is the state the user cannot get out of.
            guard removeVirtualDisplay() else { return }
            virtualDisplayFailure = nil
            virtualDisplayEnabled = false
            UserDefaults.standard.set(false, forKey: Self.virtualDisplayKey)
            record("Phone display removed")
            // The catalogue is what the phone's picker is drawn from, and a source that is gone has
            // to leave it as visibly as it arrived.
            coordinator?.refreshCatalog()
            return
        }

        guard canShowVirtualDisplay else {
            let message = "This Mac's system software does not have the virtual display API."
            virtualDisplayFailure = message
            record("Phone display unavailable: \(message)", level: .failure)
            return
        }

        isMakingVirtualDisplay = true
        defer { isMakingVirtualDisplay = false }
        do {
            let display = try VirtualDisplay()
            // Stored before anything else can fail, so a display on screen is one the model can
            // always take away again.
            virtualDisplay = display
            virtualDisplayEnabled = true
            virtualDisplayFailure = nil
            UserDefaults.standard.set(true, forKey: Self.virtualDisplayKey)
            record("""
                Phone display on screen as \(display.displayID) · \
                \(virtualDisplaySize) · pick it on the iPhone to arrange windows on
                """)
            coordinator?.refreshCatalog()
            // The window server took it, so it is on this Mac either way. What the display list
            // could not say is whether the phone can be shown it.
            if !display.appearedInList { confirmThroughCatalogue(display) }
        } catch {
            virtualDisplay = nil
            virtualDisplayEnabled = false
            UserDefaults.standard.set(false, forKey: Self.virtualDisplayKey)
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            virtualDisplayFailure = message
            record("Could not make the phone display: \(message)", level: .failure)
        }
    }

    /// Asks the capture catalogue whether the phone can actually be offered a display.
    ///
    /// The catalogue and not this process's own display list, because the catalogue is what the
    /// picker on the iPhone is drawn from. The window server creates and enables the display while
    /// `CGGetActiveDisplayList` reports only the built-in panel for the whole wait (see
    /// ``VirtualDisplay/appearedInList``), so a list that disagrees is not evidence of nothing. A
    /// display the catalogue never offers is one this row must not claim.
    ///
    /// ScreenCaptureKit is slow to notice a panel that did not exist a moment ago, so this polls.
    /// A confirmation that lands after the user has toggled again finds a different display and
    /// does nothing.
    func confirmThroughCatalogue(_ display: VirtualDisplay) {
        let id = display.displayID
        Task { @MainActor [weak self] in
            for _ in 0..<12 {
                guard let self, self.virtualDisplay?.displayID == id else { return }
                if self.catalog?.descriptor(for: .display(id)) != nil { return }
                self.coordinator?.refreshCatalog()
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard let self, self.virtualDisplay?.displayID == id else { return }
            let message = """
                The display is on this Mac, but the capture catalogue does not offer it, so the \
                phone cannot pick it.
                """
            self.record("Phone display is not offered to the phone · \(message)", level: .failure)
            // The switch has to end up where the display is, and a monitor the phone cannot be
            // shown is one this row promised and cannot deliver. Removal can itself fail, in which
            // case the switch stays on and the row says that instead.
            self.virtualDisplayFailure = message
            if self.removeVirtualDisplay() {
                self.virtualDisplayEnabled = false
                UserDefaults.standard.set(false, forKey: Self.virtualDisplayKey)
                self.coordinator?.refreshCatalog()
            }
        }
    }

    /// Takes the display away before the process does, and reports whether it went.
    ///
    /// Called from the switch, from Stop and from the termination hook, because a display that
    /// outlives the app is the one failure of this feature the user cannot repair from inside it.
    ///
    /// Kept rather than dropped when it will not leave: this property is the app's only handle on
    /// the display, so forgetting one that is still on screen would be forgetting the monitor the
    /// user is looking at.
    @discardableResult
    func removeVirtualDisplay() -> Bool {
        guard let display = virtualDisplay else { return true }
        guard display.remove() else {
            virtualDisplayFailure = "The phone display is still on screen and did not go away."
            record("The phone display did not go away when it was released", level: .failure)
            return false
        }
        virtualDisplay = nil
        return true
    }

    /// Brings back the phone-shaped display if the switch was on when this Mac was last quit.
    ///
    /// The switch is turned off first, because ``setVirtualDisplay(_:)`` refuses a request matching
    /// the state it already believes and at this point the belief comes from `UserDefaults` while
    /// the display is known not to exist. That is what makes this a request to *show* it.
    func restoreVirtualDisplay() {
        guard virtualDisplayEnabled, virtualDisplay == nil else { return }
        virtualDisplayEnabled = false
        setVirtualDisplay(true)
    }

    /// Rotates the virtual display to match the phone, and rebuilds the stream at the new size
    /// when that display is the one currently on screen.
    ///
    /// ``VirtualDisplay/setOrientation(landscape:)`` only ever switches a `CGDisplayMode`, which
    /// is not something ``VideoCoordinator`` watches for on its own: the display-added/removed
    /// notification its catalogue listens for does not distinguish a mode switch from nothing
    /// happening at all. So the same source is asked for again, through the exact path a client's
    /// own tap on a Sources tile takes, which is what makes the stream re-read the display's now
    /// different pixel size rather than go on encoding the shape it started with.
    func applyDeviceOrientation(isLandscape: Bool) {
        guard let virtualDisplay, virtualDisplay.setOrientation(landscape: isLandscape) else { return }
        if case .display(let id) = capturingSource, id == virtualDisplay.displayID {
            applyCaptureSource(.display(id))
        }
    }
}
