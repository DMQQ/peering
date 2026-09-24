import AppKit
import ApplicationServices
import Foundation
import IOKit.pwr_mgt
import Observation
import RemoteCore
import WidgetKit
import os

/// Host diagnostics, visible with:
/// `log stream --predicate 'subsystem == "pl.dmq.peering.host"'`
///
/// The window is not always reachable and every failure mode in this app is silent by nature, so
/// the unified log is where "the client connected but nothing happened" is answerable.
private let hostLog = Logger(subsystem: "pl.dmq.peering.host", category: "session")

/// Main-actor state for the host window.
///
/// The networking layer knows nothing about SwiftUI and emits ``HostEvent`` values from a
/// background queue; this type is the single place those cross back to the main actor, so the
/// session state machine never has to reason about actor isolation.
@MainActor
@Observable
final class HostModel {
    enum Status: Equatable {
        case idle
        case starting
        case listening(port: UInt16)
        case failed(String)

        var isListening: Bool {
            if case .listening = self { return true }
            return false
        }
    }

    private(set) var status: Status = .idle {
        didSet { publishHostWidgetState() }
    }
    private(set) var deviceName = "" {
        didSet { publishHostWidgetState() }
    }
    private(set) var deviceID = ""

    /// Present only while a first-time pairing is waiting on the user's comparison.
    private(set) var pairing: PairingPrompt?
    private(set) var lastOutcome: PairingOutcome?

    private(set) var connectedClients: [ConnectedClient] = [] {
        didSet { publishHostWidgetState() }
    }
    private(set) var pairedClientIDs: [String] = []

    // Held while at least one client is connected, released when the last one disconnects: the
    // display stays lit so ScreenCaptureKit does not turn a healthy stream into black frames.
    private var sleepAssertionID: IOPMAssertionID = 0

    // The assertion that keeps the Mac up on its own, with no permission prompt. It is not the
    // lid-close switch, whatever the name says: `PreventSystemSleep` is what `caffeinate -s` takes,
    // and macOS reads a closed lid on a different path. See ``setKeepRunningWithLidClosed(_:)``.
    private var lidSleepAssertionID: IOPMAssertionID = 0
    private var preferenceDisplaySleepAssertionID: IOPMAssertionID = 0
    private(set) var preventLidCloseSleep: Bool = UserDefaults.standard.bool(forKey: "preventLidCloseSleep")

    /// The key the "keep running with the lid closed" switch is stored under.
    ///
    /// A second switch rather than a stronger version of the one above, because the two are
    /// different promises at different prices: one holds an assertion that costs nothing and dies
    /// with this process, the other changes a machine setting through an administrator rule.
    private static let keepRunningWithLidClosedKey = "keepRunningWithLidClosed"

    /// The key that records that it was *this app* that ran `pmset -a disablesleep 1`.
    ///
    /// `disablesleep` is a machine setting, not an assertion: it outlives this process and a crash,
    /// so a host that dies with the switch on leaves a laptop that will not sleep in a bag. Nothing
    /// on the machine records who set it, so undoing this app's own work without undoing somebody
    /// else's means having written that fact down first.
    private static let sleepDisabledByThisAppKey = "sleepDisabledByThisApp"

    /// Whether the user wants this Mac to stay up with its lid shut.
    ///
    /// The intention, not the reading. What the machine is doing is `SleepDisabled` in `pmset -g`,
    /// and the two disagree after a crash, which ``adoptLidCloseSleepSetting()`` repairs.
    private(set) var keepRunningWithLidClosed =
        UserDefaults.standard.bool(forKey: HostModel.keepRunningWithLidClosedKey)

    /// Whether `/etc/sudoers.d/peering-sleep` is doing its job, as `sudo` reports it.
    ///
    /// Nil until it has been asked, and nil again when `sudo` will not list at all, which the row
    /// treats as not knowing rather than as not installed: the two lead to different advice.
    private(set) var lidCloseRuleInstalled: Bool?

    /// Whether an administrator prompt or a process is in flight for that row.
    ///
    /// The switch cannot move until the person at the password dialog has answered, and a control
    /// that ignores a click reads as broken, so the row draws this instead.
    private(set) var lidCloseBusy = false

    /// What went wrong the last time that row was used, until the next attempt.
    private(set) var lidCloseFailure: String?

    /// What `pmset -g` last said, or `nil` before it has been read.
    ///
    /// Kept apart from ``keepRunningWithLidClosed``, which is what the user asked for. The two come
    /// apart after a crash, a force quit, a hand edit of `/etc/sudoers.d` or somebody else's
    /// `pmset`, and the row reads both so "switched on and not in force" can be said out loud.
    private(set) var lidCloseSystemState: LidCloseSleep.SleepDisabledState?

    /// The one thing this app does before a window exists.
    ///
    /// The lid-close check is here rather than in ``start()``, which runs when the window opens,
    /// because the Mac this matters on is the one nobody is looking at: set to open at login, left
    /// in a corner with its window closed. The launch after a crash is exactly that launch.
    init() {
        Task { await adoptLidCloseSleepSetting() }
        startResourceSampling()
    }

    /// Whether a given trusted device is attached right now.
    ///
    /// Matched on the ID, the only thing the two lists have in common. The name is the client's to
    /// choose and two devices can present the same one, so comparing a name against a list of IDs
    /// is a question that is always false.
    func isConnected(_ id: String) -> Bool {
        connectedClients.contains { $0.id == id }
    }
    /// Everything the host has said, newest last.
    ///
    /// Entries rather than formatted lines, so the window can show when each thing happened and
    /// which of them went wrong.
    private(set) var log: [HostLogEntry] = []

    let permissions = Permissions()

    /// Driven from two places at once, which is why it is `@unchecked Sendable` with its own lock
    /// rather than main-actor state: commands arrive on the network queue (see the `onCommand`
    /// wiring in ``start()``), the input transform is written from wherever the coordinator reports
    /// one, and the teardown release runs on the main actor. Hopping either to the other would put
    /// pointer events behind SwiftUI or the UI behind a command queue.
    private let input = InputInjector()

    /// Physical display brightness is separate from the captured pixels, which is what lets the
    /// phone keep seeing a Mac whose local panels are dark.
    private let displayPrivacy = DisplayPrivacyController()
    private(set) var privacyModeEnabled = false

    /// The capture source the client last asked for.
    ///
    /// Cleared once the switch has been applied, and deliberately left set when it failed: a
    /// rejected switch means the client and the host disagree about what is on screen, and the
    /// window is the only place that disagreement can be seen.
    private(set) var pendingCaptureSource: CaptureSource?

    /// What is actually being streamed, once a switch has been applied.
    ///
    /// ``pendingCaptureSource`` above is the ask rather than the answer, cleared on success and
    /// left set on failure, which makes it useful for spotting a disagreement and useless for
    /// saying what is on screen.
    private(set) var capturingSource: CaptureSource?

    /// The last catalogue the resolver built, kept so a source can be named rather than shown as a
    /// number: a ``CaptureSource`` is a display ID or a pid, and "DELL P2212H" is what a person
    /// recognizes.
    private(set) var catalog: CaptureCatalog?

    /// The display name of what is being captured, if the catalogue can name it.
    var capturingSourceTitle: String? {
        guard let capturingSource, let catalog else { return nil }
        return catalog.all.first { $0.source == capturingSource }?.title
    }

    /// Everything this app has put on the network since it started, picture and sound.
    ///
    /// A counter rather than a rate: the subtraction that makes a rate is `ResourceMeter`'s, where
    /// it is tested. `nil` before there is a coordinator at all, which is a different answer from a
    /// coordinator that has sent nothing: the first is "this app is not hosting yet", the second is
    /// a zero the panel can print.
    var streamedBytes: UInt64? {
        guard let stats = coordinator?.streamStatistics else { return nil }
        // Counted separately because they are different kinds of traffic, added here because a user
        // asking what this app sends means the total. Widened on the way out: the streamer counts
        // in `Int`, and a byte count that has reached the panel is one with a sign it does not want.
        return UInt64(max(0, stats.bytesSent + stats.audioBytesSent))
    }

    /// What this app is costing the Mac, for the menu's readings.
    ///
    /// On the model rather than the window, because the menu is where these are read now and a menu
    /// bar app usually runs with its window closed. Sampled on a timer from launch because a rate is
    /// a difference between two readings: sampling when the menu opens would show nothing the first
    /// time and the whole interval since somebody last looked on the second.
    var resources = HostResourceSampler()

    /// Keeps ``resources`` current. Started once and never stopped: an app that is not hosting is
    /// still an app somebody may open the menu to ask about, and "nothing measurable" is a real
    /// answer that a blank row is not.
    private func startResourceSampling() {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                resources.sample(bytesSent: streamedBytes ?? 0)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// The last name each device gave when it connected.
    ///
    /// A pin is a public key and carries no name, and the name arrives with a connection and goes
    /// when it ends, so without keeping it the device list can only offer an ID for anything not
    /// attached right now. Persisted, because the case this is for is the device that is *not* here.
    private(set) var clientNames: [String: String] =
        UserDefaults.standard.dictionary(forKey: HostModel.clientNamesKey) as? [String: String] ?? [:]

    private static let clientNamesKey = "Peering.clientNames"

    /// What to call a device: its own name if it has ever said one, otherwise its ID.
    func displayName(for clientID: String) -> String {
        clientNames[clientID] ?? clientID
    }

    /// A still of what is being streamed, for the window's preview.
    ///
    /// `nil` when nothing is being captured: the honest answer rather than the last picture taken,
    /// since a window still showing a frame from ten minutes ago would claim the phone can see
    /// something it cannot. The caller decides how often to ask, because the caller is the view.
    func snapshot(maxWidth: Int = 640) async -> CGImage? {
        await coordinator?.snapshot(maxWidth: maxWidth)
    }

    /// Capture, encode and send. Deliberately not main-actor bound. Nil until the first client opens
    /// a video connection, because building one touches the capture catalogue, which needs Screen
    /// Recording permission.
    private var coordinator: VideoCoordinator?

    /// Runs while at least one client is attached. See ``startScreenWatch()``.
    private var screenWatchTask: Task<Void, Never>?

    /// The capture problem the attached clients have already been told about.
    ///
    /// Held so the same one is not announced twice: a denied Screen Recording grant fails again on
    /// every attempt to start a stream, and a phone told the same thing four times ignores it.
    private var announcedCaptureProblem: String?

    private var server: HostServer?
    private var relayRegistration: RelayHostRegistration?

    /// What the test button in Settings last had to say, shown beside it.
    ///
    /// Only half the answer to "does this work at all": a registered token means a phone handed one
    /// over while a session was up, and whether the relay then reached APNs is not visible from this
    /// Mac at any price, since the relay holds the key and answers nothing.
    private(set) var pushTestResult: String?

    /// Sends the same banner the terminal attention path sends, on purpose.
    @discardableResult
    func sendTestPush() -> String {
        // `registeredPushTokens` and not `allPushTokens`: the second leaves out every connected
        // phone, because a terminal needing attention is told to a connected phone over the session
        // rather than pushed, so asking it here answers "no device" whenever the person pressing the
        // button has the phone in their hand.
        let tokens = server?.registeredPushTokens() ?? []
        guard !tokens.isEmpty else {
            let message = "No device has registered a token with this Mac. Connect the phone once with this build installed."
            pushTestResult = message
            record(message, level: .warning)
            return message
        }

        for token in tokens {
            relayRegistration?.notifyDevice(
                token: token,
                title: "Terminal needs you",
                body: "A test notification from your Mac."
            )
        }

        let connected = server?.connectedPushClientCount() ?? 0
        let message = connected > 0
            ? "Sent to \(tokens.count) device\(tokens.count == 1 ? "" : "s"), \(connected) of them connected."
            : "Sent to \(tokens.count) device\(tokens.count == 1 ? "" : "s")."
        pushTestResult = message
        record(message)
        return message
    }
    private var nativeTerminalWatcher: NativeTerminalWatcher?
    private var pins: PinStore?
    private var identity: SelfSignedIdentity?
    private var spaceObserver: NSObjectProtocol?

    /// A visible tail of what has happened. Bounded because this is a status window, not a log
    /// viewer, and an unbounded array in `@Observable` state re-renders forever.
    private static let maxEvents = 60

    // MARK: - Port

    private static let portKey = "hostPort"

    /// The port this Mac listens on.
    ///
    /// Read once at launch and written when it changes, because a Mac that needs a different port
    /// needs it every time. Out of range or unset falls back to the default, so a bad value in the
    /// defaults store cannot leave the host unable to start.
    private static func storedPort() -> UInt16 {
        let stored = UserDefaults.standard.integer(forKey: portKey)
        guard let port = UInt16(exactly: stored), port > 0 else { return ProtocolInfo.defaultPort }
        return port
    }

    /// What the menu bar icon should be showing.
    ///
    /// Computed here rather than in the scene: an `@Observable` read inside `MenuBarExtra`'s label
    /// is what invalidates it.
    var menuBarState: HostMenuBarState {
        guard permissions.allRequiredGranted else { return .setupRequired }
        guard status.isListening else { return .stopped }
        if !connectedClients.isEmpty { return .streaming }
        return pairedClientIDs.isEmpty ? .waiting : .ready
    }

    /// What the host is configured to listen on, whether or not it currently is.
    private(set) var port: UInt16 = HostModel.storedPort()

    /// The port that is actually bound, once there is one.
    ///
    /// Preferred over ``port`` for anything shown to the user: the two agree while the listener is
    /// up, and while it is down the configured value is a claim about the future.
    var boundPort: UInt16 {
        if case .listening(let bound) = status { return bound }
        return port
    }

    // MARK: - Desktop widget

    private static let widgetSuiteName = "group.pl.dmq.peering"

    /// Publishes the small amount of host state a WidgetKit extension can read.
    private func publishHostWidgetState(listening override: Bool? = nil) {
        guard let defaults = UserDefaults(suiteName: Self.widgetSuiteName) else { return }
        defaults.set(override ?? status.isListening, forKey: "hostWidget.isListening")
        defaults.set(deviceName.isEmpty ? Self.defaultDeviceName : deviceName, forKey: "hostWidget.deviceName")
        defaults.set(connectedClients.map(\.name), forKey: "hostWidget.connectedNames")
        WidgetCenter.shared.reloadTimelines(ofKind: "PeeringHostControl")
    }

    /// Handles Start and Stop links from the macOS desktop widget.
    func handleWidgetCommand(_ url: URL) {
        guard url.scheme == "peering-host" else { return }
        switch url.host {
        case "start":
            start()
        case "stop":
            // On a cold launch the window's task also calls start. Let that idempotent launch
            // path settle before applying the explicit Stop command from the widget.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                self?.stop()
            }
        default:
            break
        }
    }

    /// Everything that has to happen on the way out, including the half of the lid-close switch
    /// that makes it safe to have.
    ///
    /// `pmset -a disablesleep 1` is a machine setting and outlives this process, so a Mac whose
    /// owner turned it on and quit the app would never sleep again with nothing on screen to say
    /// why. The restore runs only when this app set it, so a machine disabled by something else is
    /// left as it was found; see ``sleepDisabledByThisAppKey``.
    ///
    /// Synchronous, and it stays that way: the process is going away, so there is no later in which
    /// to finish an `await`.
    func prepareForTermination() {
        publishHostWidgetState(listening: false)
        // First, because it is the one thing here that changes the user's Mac in a way they would
        // have to repair from outside this app: everything below is a setting being put back, this
        // is a monitor being taken away. The window server does collect a virtual display when the
        // process dies, but that is an undocumented courtesy of a private API and not worth
        // depending on.
        removeVirtualDisplay()
        // Cancelled before the restore rather than after, so a check already in flight cannot land
        // on a model that is on its way out and put the switch back on.
        batteryWatchdog?.cancel()
        batteryWatchdog = nil
        restoreSleepDisabledIfOurs()
    }

    /// Puts the machine back to sleeping normally, if it was this app that stopped it.
    ///
    /// A failure here leaves the marker in place on purpose: the setting is still on, and the next
    /// launch is the next chance to undo it.
    private func restoreSleepDisabledIfOurs() {
        guard UserDefaults.standard.bool(forKey: Self.sleepDisabledByThisAppKey) else { return }
        switch LidCloseSleepControl.restoreSleepSilently() {
        case .done:
            UserDefaults.standard.set(false, forKey: Self.sleepDisabledByThisAppKey)
        case .failed(let message):
            // Straight to the unified log rather than ``record(_:level:)``: the window is closing
            // and an entry in a list nobody will read is not a diagnostic.
            hostLog.notice("could not restore lid-close sleep on quit: \(message, privacy: .public)")
        case .cancelled:
            break
        }
    }

    /// Changes the port, and restarts the listener if one is running.
    ///
    /// A restart rather than a rebind, because there is no rebinding: the port is fixed when the
    /// listener is created. Heavy for one number, since the capture stream and every connected
    /// device go with it, but the alternative is a host that reports one port and listens on
    /// another.
    func setPort(_ newPort: UInt16) {
        guard newPort != port, newPort > 0 else { return }
        port = newPort
        UserDefaults.standard.set(Int(newPort), forKey: Self.portKey)

        guard server != nil else { return }
        stop()
        start()
    }

    // MARK: - Capture

    private static let captureResolutionKey = "captureResolution"
    private static let captureFrameRateKey = "captureFrameRate"
    private static let captureCodecKey = "captureCodec"

    /// What the picture is made of: how many pixels a frame carries, and how many frames a second.
    ///
    /// A value this version cannot read falls back to the default rather than to the other case, so
    /// a key written by a later build cannot leave the stream smaller or slower than anyone chose.
    /// The frame rate needs no absence check: `integer(forKey:)` answers 0 for a key never written,
    /// and 0 is not a rate any stream can be built at.
    private static func storedCaptureResolution() -> CaptureResolution {
        UserDefaults.standard.string(forKey: captureResolutionKey)
            .flatMap { CaptureResolution(rawValue: $0) } ?? .full
    }

    private static func storedCaptureFrameRate() -> CaptureFrameRate {
        let stored = UserDefaults.standard.integer(forKey: captureFrameRateKey)
        return CaptureFrameRate(rawValue: stored) ?? .sixty
    }

    private static func storedCaptureCodec() -> VideoCodec {
        UserDefaults.standard.string(forKey: captureCodecKey).flatMap(VideoCodec.init(rawValue:)) ?? .h264
    }

    private(set) var captureResolution: CaptureResolution = HostModel.storedCaptureResolution()
    private(set) var captureFrameRate: CaptureFrameRate = HostModel.storedCaptureFrameRate()
    private(set) var captureCodec: VideoCodec = HostModel.storedCaptureCodec()

    /// These take effect on the next stream, not on the one already running.
    ///
    /// A surface's size and its frame interval are fixed when the `SCStream` is built, so a capture
    /// in flight can only be replaced, which would drop the picture and cost a keyframe for a
    /// setting the user is still deciding on. Both define the capture and encoder timelines.
    func setCaptureResolution(_ resolution: CaptureResolution) {
        captureResolution = resolution
        UserDefaults.standard.set(resolution.rawValue, forKey: Self.captureResolutionKey)
        applyCaptureFormat()
    }

    func setCaptureFrameRate(_ frameRate: CaptureFrameRate) {
        captureFrameRate = frameRate
        UserDefaults.standard.set(frameRate.rawValue, forKey: Self.captureFrameRateKey)
        applyCaptureFormat()
    }

    func setCaptureCodec(_ codec: VideoCodec) {
        captureCodec = codec
        UserDefaults.standard.set(codec.rawValue, forKey: Self.captureCodecKey)
        record("Codec set to \(codec.title); it applies when the next stream starts")
    }

    /// Hands the pair to the coordinator, which reads them when a capture starts.
    ///
    /// Silent while nothing is listening, which is ordinary rather than a failure: the values live
    /// in the stored properties above and ``start()`` gives a coordinator built afterwards both.
    /// Written as one call so a coordinator cannot build the next stream out of two moments.
    private func applyCaptureFormat() {
        coordinator?.setCaptureFormat(resolution: captureResolution, frameRate: captureFrameRate)
    }

    // MARK: - Virtual display

    private static let virtualDisplayKey = "hostVirtualDisplay"

    /// Whether this Mac is showing the phone-shaped display that exists only in software.
    ///
    /// Stored, because it is a change to the user's Mac rather than to a session: the display comes
    /// back at the next launch if it was on at the last. There is no case where the switch is on
    /// and the display is not: a failed creation turns it back off and says why.
    private(set) var virtualDisplayEnabled = UserDefaults.standard.bool(forKey: HostModel.virtualDisplayKey)

    /// Why the last attempt failed, if it did, for the row to show.
    private(set) var virtualDisplayFailure: String?

    /// Whether this Mac's system software has the API at all.
    ///
    /// Read by the row so the switch is offered as off-and-unavailable rather than thrown and
    /// failing, and by ``start()`` so a Mac that never had it does not try at every launch.
    var canShowVirtualDisplay: Bool { VirtualDisplay.isAvailable }

    /// What the virtual display is, which is also the size the row promises.
    var virtualDisplaySize: String {
        "\(Int(VirtualDisplay.phoneShaped.width))×\(Int(VirtualDisplay.phoneShaped.height))"
    }

    /// The display this host made, held for as long as it should exist.
    ///
    /// The model is the owner and that is the teardown design: the display goes away when the last
    /// reference to it does, so every path that has to take it down (the switch, Stop, quitting, a
    /// process that dies without either) comes down to this property reaching `nil`. Keeping it
    /// anywhere else would be a monitor the user cannot get rid of.
    private var virtualDisplay: VirtualDisplay?

    /// Whether a display is being made right now.
    ///
    /// The wait inside ``VirtualDisplay`` turns the main run loop, so a second click can arrive
    /// while the first display is still being made. The window server refuses a second display with
    /// the same vendor, product and serial outright ("no displayID available"), so that click has
    /// to be dropped rather than attempted.
    private var isMakingVirtualDisplay = false

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
    private func confirmThroughCatalogue(_ display: VirtualDisplay) {
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
    private func removeVirtualDisplay() -> Bool {
        guard let display = virtualDisplay else { return true }
        guard display.remove() else {
            virtualDisplayFailure = "The phone display is still on screen and did not go away."
            record("The phone display did not go away when it was released", level: .failure)
            return false
        }
        virtualDisplay = nil
        return true
    }

    // MARK: - Lifecycle

    func start() {
        guard server == nil else { return }
        // There is no useful partial host: without Screen Recording the client receives no picture,
        // without Accessibility its input is silently discarded. Onboarding requests both and calls
        // back here only when they are present.
        guard permissions.allRequiredGranted else {
            status = .idle
            return
        }
        // Before anything opens a session of its own: whatever is in the store at this moment was
        // left by the last process. See ``adoptAbandonedSessions()``.
        adoptAbandonedSessions()
        status = .starting
        if preventLidCloseSleep {
            acquireLidSleepAssertion()
            acquirePreferenceDisplaySleepAssertion()
        }
        let device = DeviceIdentity.loadOrCreate(defaultName: Self.defaultDeviceName)
        deviceName = device.name
        deviceID = device.id

        let pins = PinStore(service: "pl.dmq.peering.pins")
        self.pins = pins
        pairedClientIDs = pins.peerIDs

        let identity: SelfSignedIdentity
        do {
            // The common name is decorative — the peer takes the real name from
            // `ServerHello`, so renaming the Mac never invalidates anything.
            identity = try SelfSignedIdentity.loadOrCreate(role: .server, commonName: device.name)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            status = .failed(message)
            record("Identity unavailable: \(message)", level: .failure)
            return
        }
        self.identity = identity
        record("Identity ready · key \(identity.publicKeyBytes.count) bytes")

        // Until something is being captured there is no captured surface to map into, so the
        // pointer is mapped against the display the user is looking at. That is exactly right for
        // display capture, which is what a client gets if it never picks a source.
        input.transform = DisplayGeometry.activeTransform()

        // Built here but not started: constructing a pipeline only stores the resolver, and reading
        // the catalogue is what needs permission, which happens on the first video connection.
        //
        // The resolver's invalidation callback reaches the coordinator built below it, going through
        // `self` because the callback fires on whatever thread observed the notification and this is
        // the same main-actor hop every other callback here takes.
        // Re-push the catalog when the user switches Spaces, so the number the client's Space picker
        // highlights follows them. The picture of the desktop they arrive on is taken by the
        // resolver on its own schedule, once the switch has finished on screen, and pushes a second
        // catalogue. Neither push stands in for the other.
        let spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.coordinator?.refreshCatalog()
        }
        self.spaceObserver = spaceObserver

        let resolver = ScreenCaptureSourceResolver { [weak self] in
            Task { @MainActor [weak self] in self?.coordinator?.refreshCatalog() }
        }
        let pipeline = CapturePipeline(resolver: resolver, codec: captureCodec)
        let coordinator = VideoCoordinator(pipeline: pipeline)
        // Before any capture can start: the first video connection may arrive seconds from now, and
        // a coordinator not told would build the first stream of the session from its own defaults.
        // The setters cannot do it from here, since they write to the property below and this
        // coordinator is not that property yet.
        coordinator.setCaptureFormat(
            resolution: captureResolution,
            frameRate: captureFrameRate
        )
        coordinator.onCatalog = { [weak self] catalog in
            Task { @MainActor [weak self] in
                // Kept as well as forwarded: the window names the capture source from it.
                self?.catalog = catalog
                self?.server?.broadcastCatalog(catalog)
            }
        }
        coordinator.onStatus = { [weak self] message in
            Task { @MainActor [weak self] in self?.record(message) }
        }
        coordinator.onFailure = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.apply(.failed(error.localizedDescription))
                self.announceCaptureProblem(error)
            }
        }
        coordinator.onInputTransform = { [weak self] transform in
            // Straight through, not hopped to the main actor: `input` is not UI state and its
            // `transform` is lock-guarded for exactly this.
            guard let transform else { return }
            self?.input.transform = transform
        }
        // The same value from the only observer that sees it change. For an application or a window
        // this is the authoritative answer: the one above is built from geometry read when capture
        // started, and a window dragged two seconds later has moved since.
        coordinator.onGeometry = { [weak self] geometry in
            guard let transform = geometry.inputTransform else { return }
            self?.input.transform = transform
        }
        coordinator.onSourceChanged = { [weak self] source in
            Task { @MainActor [weak self] in self?.capturingSource = source }
        }
        self.coordinator = coordinator

        let server = HostServer(identity: identity, device: device, pins: pins, port: port)
        server.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in self?.apply(event) }
        }

        // The server has already established that a live authorized control session holds this
        // client's key. That check is the only thing between an open port and the user's screen,
        // and it is not repeated here.
        server.onVideoConnection = { [weak coordinator] peer in
            coordinator?.handleVideoConnection(peer)
        }

        // A client whose picture is not arriving asks for it on the control channel, and that
        // request has to reach the pipeline with the connection it arrived on. Straight through,
        // off the main actor: deciding it is a question about sockets and an encoder.
        server.onVideoTransport = { [weak coordinator] clientKey, request, controlPeer in
            coordinator?.setVideoTransport(request, clientKey: clientKey, controlPeer: controlPeer)
        }

        // The same shape for the relay's datagram path: the request comes with the client's key and
        // the allocation the relay handed over, and the answer is the secret that seals what goes on
        // it, or nil, which the session turns into silence and the client reads as "the picture stays
        // where it is".
        server.onVideoKeyRequest = { [weak coordinator] clientKey, relay in
            coordinator?.enableVideoDatagrams(clientKey: clientKey, relay: relay)
        }

        // And the picture's on/off switch, the same shape once more: straight through, off the main
        // actor, because it is a decision about a socket and an encoder. Nothing here ends a session,
        // so a client that asks for no frames keeps its control channel, its shells and the sleep
        // assertion this Mac holds while it is connected, and only the frames stop.
        server.onVideoEnabled = { [weak coordinator] clientKey, enabled in
            coordinator?.setVideoEnabled(enabled, clientKey: clientKey)
        }

        // `input` is captured directly rather than reached through `self`: injecting a mouse move is
        // not UI work, and hopping to the main actor would put every pointer event behind whatever
        // SwiftUI happens to be doing.
        let input = self.input
        server.onCommand = { [weak self] command in
            if case .setCaptureSource(let source) = command {
                Task { @MainActor [weak self] in
                    self?.pendingCaptureSource = source
                    self?.applyCaptureSource(source)
                }
                return
            }
            if case .launchApplication(let bundleIdentifier) = command {
                Task { @MainActor [weak self] in
                    self?.launchApplication(bundleIdentifier: bundleIdentifier)
                }
                return
            }
            if case .reportDeviceOrientation(let isLandscape) = command {
                Task { @MainActor [weak self] in
                    self?.applyDeviceOrientation(isLandscape: isLandscape)
                }
                return
            }
            if case .switchToSpace(let display, let index) = command {
                Task { @MainActor [weak self] in
                    // `performSwitch` returns whether the window server *accepted* the move, which
                    // is the whole difference between a tile that works and one that silently does
                    // nothing. The two are indistinguishable from the phone.
                    let switched = switchToSpace(display: display, index: index)
                    self?.record(
                        switched
                            ? "Desktop \(index) on display \(display) accepted"
                            : "Desktop \(index) on display \(display) refused by the window server",
                        level: switched ? .info : .warning
                    )
                }
                return
            }
            if case .switchSpace(let direction) = command {
                Task { @MainActor in
                    switchSpaceRelative(direction: direction)
                }
                return
            }
            if case .setStreamQuality(let fps, let bitrateKbps) = command {
                coordinator.setStreamQuality(fps: fps, bitrateKbps: bitrateKbps)
                return
            }
            if case .refreshSpacePreviews = command {
                // Not hopped to the main actor: the capture is the resolver's own work on its own
                // queue, and the only main-actor part, reading the Space lists, it does itself.
                coordinator.refreshSpacePreviews()
                return
            }
            if case .refreshSourceThumbnails = command {
                // The same shape: the screenshots are taken on the resolver's own tasks and the
                // answer travels on the catalogue push, so nothing here waits.
                coordinator.refreshSourceThumbnails()
                return
            }
            if case .setPrivacyMode(let enabled) = command {
                Task { @MainActor [weak self] in self?.setPrivacyMode(enabled) }
                return
            }
            if case .lockScreen = command {
                Task { @MainActor in
                    let src = CGEventSource(stateID: .hidSystemState)
                    // Keycode 12 is `Q`. 0x19 is `L`, which is silently not the lock shortcut.
                    let down = CGEvent(keyboardEventSource: src, virtualKey: 12, keyDown: true)
                    let up   = CGEvent(keyboardEventSource: src, virtualKey: 12, keyDown: false)
                    down?.flags = [.maskCommand, .maskControl]
                    up?.flags   = [.maskCommand, .maskControl]
                    down?.post(tap: .cghidEventTap)
                    up?.post(tap: .cghidEventTap)
                    hostLog.notice("lock screen shortcut posted")
                }
                return
            }
            // A mosaic takes no input. Every other source is something a click can mean on; a
            // canvas is not, because which machine coordinate a point means depends on which tile
            // it landed in, and the app decides that rather than posting it at the Mac. The client
            // sends nothing while a canvas is up, so this is the belt to that brace: a stray input
            // would otherwise be placed through the last single-source transform, a click on a
            // window nobody is looking at. Selecting a tile is an ordinary source switch.
            if command.isUserInput, coordinator.isShowingMosaic {
                return
            }
            input.perform(command)
        }

        // The reading is asked of the pasteboard rather than of one type on it, because only this
        // end can find out whether what was copied is a picture or a line of text, and the answer
        // decides how it travels. Both hop to the main thread: `NSPasteboard` is not safe from
        // anywhere else, and the session's queue is not the main thread.
        server.onRequestClipboard = {
            DispatchQueue.main.sync { ClipboardPasteboard.read() }
        }
        server.onReceiveClipboard = { payload in
            DispatchQueue.main.async { ClipboardPasteboard.write(payload) }
        }

        self.server = server

        do {
            try server.start()
            let registration = RelayHostRegistration(
                device: device,
                identity: identity,
                onSession: { [weak server] session in server?.connectThroughRelay(session) },
                onStatus: { [weak self] message in
                    Task { @MainActor [weak self] in self?.record(message) }
                }
            )
            server.onPushNeeded = { [weak registration] token, message in
                registration?.notifyDevice(token: token, title: "Terminal needs you", body: message)
            }
            relayRegistration = registration
            registration.start()

            let watcher = NativeTerminalWatcher()
            watcher.onAttention = { [weak server, weak registration] message in
                let tokens = server?.allPushTokens() ?? []
                // The line that answers "why did nothing arrive": a terminal watched from outside
                // has no session channel to be told over, so the only way this reaches the phone is
                // a token handed over while a session was up. With none there is nothing to send to
                // and nothing on screen to say so.
                if tokens.isEmpty {
                    hostLog.notice("a terminal needs the user and no device token is registered: \(message, privacy: .public)")
                }
                for token in tokens {
                    registration?.notifyDevice(token: token, title: "Terminal needs you", body: message)
                }
            }
            watcher.start()
            nativeTerminalWatcher = watcher
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            status = .failed(message)
            record(message)
            self.server = nil
        }

        // Last, deliberately: the display takes a few hundred milliseconds to appear and this waits
        // for it, and nothing above is waiting on the display. A client that connects during those
        // milliseconds is served a catalogue without it and pushed a second one when it arrives.
        restoreVirtualDisplay()
    }

    /// Brings back the phone-shaped display if the switch was on when this Mac was last quit.
    ///
    /// The switch is turned off first, because ``setVirtualDisplay(_:)`` refuses a request matching
    /// the state it already believes and at this point the belief comes from `UserDefaults` while
    /// the display is known not to exist. That is what makes this a request to *show* it.
    private func restoreVirtualDisplay() {
        guard virtualDisplayEnabled, virtualDisplay == nil else { return }
        virtualDisplayEnabled = false
        setVirtualDisplay(true)
    }

    func stop() {
        // Before the listener goes, while the reason is still on screen. Stopping is the one
        // disconnect that is not the client's doing, so a modifier held when the user pressed Stop
        // is exactly as stuck as one held by a client that crashed. The sessions cancelled below
        // may or may not report a disconnect of their own, so this does not wait on them.
        input.releaseAll()
        setPrivacyMode(false)
        // Before the listener goes, and before the process can outlive it: a stopped host that has
        // left a monitor behind is the one state the user cannot repair from the window.
        removeVirtualDisplay()
        server?.stop()
        server = nil
        relayRegistration?.stop()
        relayRegistration = nil
        nativeTerminalWatcher?.stop()
        nativeTerminalWatcher = nil
        coordinator?.stop()
        coordinator = nil
        if let observer = spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            spaceObserver = nil
        }
        status = .idle
    }

    /// Switches what is being captured, at the client's request.
    ///
    /// The stream is rebuilt for the new source while the video connection is left alone, so the
    /// client sees a new config and keyframe rather than a reconnect. The new source is looked up
    /// at switch time, so one that has since disappeared fails here rather than at connection time,
    /// which is why the failure names the source.
    private func applyCaptureSource(_ source: CaptureSource) {
        guard let coordinator else {
            // Nothing is being captured, so there is nothing to switch. The request is kept so the
            // window shows what the client last asked for; a client that has not opened a video
            // connection yet gets the default source, not this one.
            record("Capture source requested before any video connection")
            return
        }

        Task { [weak self] in
            do {
                try await coordinator.switchSource(source)
                self?.pendingCaptureSource = nil
                // After the switch rather than before: raising an app whose capture then fails
                // would bring the wrong thing forward and leave it there.
                self?.raiseApplication(for: source)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                self?.record("Could not switch capture source: \(message)", level: .failure)
            }
        }
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
    private func applyDeviceOrientation(isLandscape: Bool) {
        guard let virtualDisplay, virtualDisplay.setOrientation(landscape: isLandscape) else { return }
        if case .display(let id) = capturingSource, id == virtualDisplay.displayID {
            applyCaptureSource(.display(id))
        }
    }

    /// Brings a captured application to the front, so what the client sees and where its clicks
    /// land are the same thing.
    ///
    /// Capturing an application is not controlling it, and the gap is invisible from the client.
    /// ScreenCaptureKit composites the app's *windows*, so the client sees the app whether it is
    /// occluded, minimised or on another Space. Input goes to the HID tap, where the window server
    /// hit-tests the real screen and hands the click to whatever is genuinely at those coordinates.
    /// The user sees the app, clicks where it appears to be, and hits whatever is on top of it.
    ///
    /// `.activateAllWindows` rather than a plain activation, because ``InputTransform`` for an
    /// application is the union of every window it owns.
    ///
    /// The cost: this moves the app in front of whatever the Mac's own user was doing, and switches
    /// Spaces if its windows are elsewhere.
    private func raiseApplication(for source: CaptureSource) {
        guard case .application(let pid) = source,
              let running = NSRunningApplication(processIdentifier: pid)
        else { return }

        running.activate(options: [.activateAllWindows])
    }

    /// Opens a GUI application by the bundle identifier offered in the catalogue, then follows it
    /// into application capture. Executable paths never cross the network.
    private func launchApplication(bundleIdentifier: String) {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard !bundleIdentifier.isEmpty,
              bundleIdentifier.utf8.count <= 255,
              bundleIdentifier.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else {
            record("Could not launch application: invalid or unavailable bundle identifier", level: .failure)
            return
        }

        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { $0.activationPolicy == .regular }) {
            running.activate()
            let target = launchTargetDisplayID
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let target {
                    await self.relocateLaunchedApplication(running, toDisplay: target)
                }
                self.switchToLaunchedApplication(running)
            }
            return
        }

        let target = launchTargetDisplayID
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] application, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.record("Could not launch application: \(error.localizedDescription)", level: .failure)
                    return
                }
                guard let application else {
                    self.record("Application launched but no running process was returned", level: .failure)
                    return
                }
                self.record("Opened \(application.localizedName ?? bundleIdentifier)")
                self.coordinator?.refreshCatalog()
                if let target {
                    await self.relocateLaunchedApplication(application, toDisplay: target)
                }
                self.switchToLaunchedApplication(application)
            }
        }
    }

    /// The display a freshly launched app's windows should land on: the one the client is
    /// currently looking at, so the app picker never hands back a window on a desktop the phone
    /// cannot see. `NSWorkspace` has no notion of "the client's display" — left alone, a launch
    /// opens onto whatever the Mac's own window server considers current, which on a Mac driving
    /// a virtual display is the built-in screen's desktop, not the virtual one.
    ///
    /// Falls back to the virtual display whenever one exists, even while the client is looking at
    /// a single captured application: that display's Space is what the phone otherwise treats as
    /// home, and a launch has nowhere else meaningful to prefer.
    private var launchTargetDisplayID: UInt32? {
        if case .display(let id) = capturingSource { return id }
        return virtualDisplay?.displayID
    }

    /// Moves every window `application` currently owns onto `displayID`'s bounds.
    ///
    /// Spaces are a window/display pairing kept by the window server, not a property of the
    /// window itself: a window whose position crosses onto another display joins whatever Space
    /// that display is currently showing. So repositioning is all this needs — no Space switch,
    /// and nothing about `SpaceReader`'s chord dance applies here.
    ///
    /// Polled rather than tried once: a launch completion can precede the app actually having a
    /// window, the same race ``switchToLaunchedApplication`` already accounts for.
    private func relocateLaunchedApplication(_ application: NSRunningApplication, toDisplay displayID: UInt32) async {
        for attempt in 0..<20 {
            if relocateWindows(ofPID: application.processIdentifier, toDisplay: displayID) { return }
            if attempt < 19 {
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    /// Repositions every movable window of `pid` into `displayID`'s bounds. Returns whether it
    /// found any windows at all, which is what the poll above is waiting on.
    private func relocateWindows(ofPID pid: pid_t, toDisplay displayID: UInt32) -> Bool {
        var ref: CFTypeRef?
        let appElement = AXUIElementCreateApplication(pid)
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement], !windows.isEmpty
        else { return false }

        let bounds = CGDisplayBounds(displayID)
        for (index, window) in windows.enumerated() {
            var settable: DarwinBoolean = false
            guard AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &settable) == .success,
                  settable.boolValue
            else { continue }

            var size = CGSize.zero
            var sizeRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
               let sizeValue = sizeRef, CFGetTypeID(sizeValue) == AXValueGetTypeID() {
                AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
            }

            // Cascaded so a second window launched moments later is not stacked exactly on the
            // first, and clamped so a window sized for the Mac's own screen does not spill off a
            // much smaller virtual display.
            let offset = CGFloat(index) * 24
            let maxX = max(bounds.minX, bounds.maxX - size.width)
            let maxY = max(bounds.minY, bounds.maxY - size.height)
            var origin = CGPoint(
                x: min(bounds.minX + 40 + offset, maxX),
                y: min(bounds.minY + 40 + offset, maxY)
            )

            guard let value = AXValueCreate(.cgPoint, &origin) else { continue }
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
        return true
    }

    private func switchToLaunchedApplication(_ application: NSRunningApplication) {
        guard let coordinator else {
            record("Application opened; capture is not connected", level: .warning)
            return
        }
        let source = CaptureSource.application(application.processIdentifier)
        pendingCaptureSource = source

        // A launch completion can precede creation of the first capturable window, so poll the
        // observable result rather than assuming a live process means SCK has something to capture.
        Task { [weak self, weak coordinator] in
            guard let self, let coordinator else { return }
            var lastError: Error?
            for attempt in 0..<20 {
                do {
                    try await coordinator.switchSource(source)
                    await MainActor.run { self.pendingCaptureSource = nil }
                    return
                } catch {
                    lastError = error
                    if attempt < 19 {
                        try? await Task.sleep(for: .milliseconds(150))
                    }
                }
            }
            let message = (lastError as? LocalizedError)?.errorDescription
                ?? lastError.map(String.init(describing:))
                ?? "The application did not expose a capturable window."
            await MainActor.run { self.record("Could not switch to application: \(message)", level: .failure) }
        }
    }

    func unpairAll() {
        guard let pins else { return }
        if pins.removeAll() {
            pairedClientIDs = []
            // The names go with the pins: keeping them would leave a device list naming phones it
            // will never let back in.
            clientNames = [:]
            UserDefaults.standard.removeObject(forKey: Self.clientNamesKey)
            record("All paired clients removed")
        } else {
            record("Could not clear paired clients", level: .failure)
        }
    }

    /// Revokes one phone without disturbing the others.
    ///
    /// Go through the server while it is running so an already-connected phone is disconnected as
    /// well as removed from the Keychain. Before startup there cannot be an active session, so the
    /// store itself is sufficient.
    /// Drops a phone's connection and leaves it trusted.
    ///
    /// Not forgetful: the pin stays, so the same phone reconnects on its own and no pairing code is
    /// needed. For the case where the session should stop now, because someone else wants the
    /// screen or the wrong device is attached.
    func disconnect(clientID: String) {
        server?.disconnect(clientID: clientID)
        record("Disconnected \(displayName(for: clientID))")
    }

    func unpair(clientID: String) {
        guard let pins else { return }
        let removed = server?.unpair(clientID: clientID) ?? pins.remove(peerID: clientID)
        guard removed else {
            record("Could not remove \(displayName(for: clientID))", level: .failure)
            return
        }

        let name = displayName(for: clientID)
        pairedClientIDs.removeAll { $0 == clientID }
        connectedClients.removeAll { $0.id == clientID }
        clientNames.removeValue(forKey: clientID)
        UserDefaults.standard.set(clientNames, forKey: Self.clientNamesKey)
        record("Forgot \(name)")
    }

    func refreshPermissions() {
        permissions.refresh()
    }

    // MARK: - Event handling

    private func apply(_ event: HostEvent) {
        switch event {
        case .listening(let port):
            status = .listening(port: port)
            record("Listening on port \(port) as “\(deviceName)”")

        case .stopped:
            status = .idle
            record("Stopped listening")

        case .clientConnected(let clientID, let clientName, let detail):
            if !isConnected(clientID) {
                connectedClients.append(
                    ConnectedClient(id: clientID, name: clientName, since: Date())
                )
            }
            // Recorded before anything is shown, so the name outlives the connection that carried
            // it. Assigned rather than only inserted, because a client may rename itself.
            if clientNames[clientID] != clientName {
                clientNames[clientID] = clientName
                UserDefaults.standard.set(clientNames, forKey: Self.clientNamesKey)
            }
            beginSession(id: clientID, name: clientName)
            startScreenWatch()
            record("\(clientName) connected · \(detail)")
            // A client that has just arrived has no source list, so it is sent one now rather than
            // waiting for an application to launch. It is also the first read of the catalogue,
            // which is what needs Screen Recording permission: a refusal here is logged and ignored,
            // and the video path reports it properly if the client then asks for a source.
            coordinator?.refreshCatalog()
            acquireSleepAssertion()

        case .clientDisconnected(let clientID, let clientName):
            connectedClients.removeAll { $0.id == clientID }
            endSession(id: clientID)
            // The last one out stops the watch. Anybody still attached keeps being told.
            if connectedClients.isEmpty { stopScreenWatch() }
            record("\(clientName) disconnected")
            // The moment nothing is left that can release what this client was holding: a client
            // that dies mid-chord or mid-drag takes its key-up with it, and the Mac would sit
            // holding ⌘ or a mouse button until a real one arrived from the keyboard. Only on the
            // last client, because the held state is the Mac's, so releasing it while another
            // client is connected would drop a modifier that client is holding for real.
            if connectedClients.isEmpty {
                input.releaseAll()
                releaseSleepAssertion()
                setPrivacyMode(false)
            }

        case .pairingCode(let code, let clientName, let isRemote):
            pairing = PairingPrompt(clientName: clientName, code: code, isRemote: isRemote)
            record(isRemote
                   ? "Pairing request from \(clientName), over the relay"
                   : "Pairing request from \(clientName)")
            // The code is not logged: the unified log is readable by any local process, and the
            // digits are already on screen for the user to compare.
            hostLog.notice("pairing code displayed for \(clientName, privacy: .public)")

        case .pairingCompleted(let clientName, let accepted):
            pairing = nil
            lastOutcome = PairingOutcome(clientName: clientName, accepted: accepted)
            pairedClientIDs = pins?.peerIDs ?? []
            record(accepted ? "Paired with \(clientName)" : "Pairing with \(clientName) rejected")

        case .failed(let message):
            record(message)
            // A failure while listening is worth surfacing as status; a per-connection one is not,
            // or one bad client would blank out a healthy listener.
            if !status.isListening {
                status = .failed(message)
            }
        }
    }

    private func record(_ message: String, level: HostLogEntry.Level = .info) {
        // `.public` because these lines are the diagnostics, and the one sensitive value, the
        // pairing code, is deliberately never in them.
        hostLog.notice("\(message, privacy: .public)")
        log.append(HostLogEntry(level: level, message: message))
        if log.count > Self.maxEvents {
            log.removeFirst(log.count - Self.maxEvents)
        }
    }

    /// Dims or restores every display for which macOS exposes brightness control.
    private func setPrivacyMode(_ enabled: Bool) {
        if enabled {
            guard !privacyModeEnabled else { return }
            do {
                let count = try displayPrivacy.enable()
                privacyModeEnabled = true
                record("Privacy Mode enabled on \(count) display\(count == 1 ? "" : "s")")
            } catch {
                privacyModeEnabled = false
                let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                record("Could not enable Privacy Mode: \(message)", level: .failure)
                server?.broadcastNotice(NoticePayload(
                    message: "Privacy Mode could not dim this Mac's displays.",
                    symbol: "display.trianglebadge.exclamationmark"
                ))
            }
        } else {
            guard privacyModeEnabled else {
                // Also repairs a persisted level after an interrupted run.
                displayPrivacy.restore()
                return
            }
            displayPrivacy.restore()
            privacyModeEnabled = false
            record("Privacy Mode disabled; display brightness restored")
        }
    }

    /// The whole log as text, for the window's copy button.
    var logText: String { log.plainText }

    /// Finished sessions, newest first.
    ///
    /// Persisted and bounded: a host running for months should not carry a year of history in
    /// `UserDefaults` to answer a question about this week.
    private(set) var sessions: [HostSessionRecord] =
        UserDefaults.standard.data(forKey: HostModel.sessionsKey)
            .flatMap { try? JSONDecoder().decode([HostSessionRecord].self, from: $0) } ?? []

    /// A session that has begun and has not been written down as finished.
    ///
    /// Persisted as it goes, because a record written only at the end is lost whenever the end
    /// never arrives: the host is quit, crashes, or is rebuilt while a phone is attached, which is
    /// exactly the session someone would want to look up.
    private struct OpenSession: Codable {
        var deviceName: String
        var started: Date
        /// The streamer's byte count when this session began. The count is cumulative and never
        /// reset, so a session's cost is the difference between a later read and this.
        var bytesAtStart: Int
        /// The last moment this session was known to be alive. Becomes its end time if no end ever
        /// arrives, which is the honest answer: it was alive then, and nothing since.
        var lastSeen: Date
        /// Bytes counted as of ``lastSeen``. Kept current as the session runs rather than derived at
        /// the end, because a session that never ends has no end to derive it from.
        var bytes: Int
    }

    /// Sessions in flight, by client ID — more than one phone can be attached at once.
    private var openSessions: [String: OpenSession] =
        UserDefaults.standard.data(forKey: HostModel.openSessionsKey)
            .flatMap { try? JSONDecoder().decode([String: OpenSession].self, from: $0) } ?? [:]

    private static let sessionsKey = "Peering.sessions"
    private static let openSessionsKey = "Peering.openSessions"
    private static let maxSessions = 20

    private func saveOpenSessions() {
        guard let data = try? JSONEncoder().encode(openSessions) else { return }
        UserDefaults.standard.set(data, forKey: Self.openSessionsKey)
    }

    /// Whatever was in flight when the host last stopped.
    ///
    /// Its presence at launch is the signal: nothing else clears this store, so an entry surviving
    /// to a fresh process means a phone was attached when the last one ended, and no disconnect was
    /// ever going to arrive for it.
    /// Whether the store has been checked for what the last process abandoned. Once per process:
    /// after that, anything in `openSessions` is one of ours, running.
    private var hasAdoptedAbandonedSessions = false

    private func adoptAbandonedSessions() {
        guard !hasAdoptedAbandonedSessions else { return }
        hasAdoptedAbandonedSessions = true
        guard !openSessions.isEmpty else { return }
        // Oldest first, so the list still reads newest-first after each is inserted at the top.
        for open in openSessions.values.sorted(by: { $0.started < $1.started }) {
            record(
                "\(open.deviceName) was still connected when the host last stopped",
                level: .warning
            )
            sessions.insert(
                HostSessionRecord(
                    deviceName: open.deviceName,
                    started: open.started,
                    ended: open.lastSeen,
                    bytes: open.bytes
                ),
                at: 0
            )
        }
        if sessions.count > Self.maxSessions {
            sessions.removeLast(sessions.count - Self.maxSessions)
        }
        openSessions = [:]
        saveOpenSessions()
        saveSessions()
    }

    private func saveSessions() {
        if let data = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(data, forKey: Self.sessionsKey)
        }
    }

    private func beginSession(id: String, name: String) {
        openSessions[id] = OpenSession(
            deviceName: name,
            started: Date(),
            bytesAtStart: coordinator?.streamStatistics.bytesSent ?? 0,
            lastSeen: Date(),
            bytes: 0
        )
        saveOpenSessions()
        hostLog.notice("session opened for \(id, privacy: .public)")
    }

    /// Keeps the in-flight sessions' figures current.
    ///
    /// Called from the screen watch, which already ticks every two seconds while anybody is
    /// attached. Written every thirtieth tick rather than every one, since this is `UserDefaults`
    /// and a figure half a minute stale is worth more than a write per tick.
    private func touchOpenSessions() {
        guard !openSessions.isEmpty, let sent = coordinator?.streamStatistics.bytesSent else { return }
        let now = Date()
        for (id, var open) in openSessions {
            open.lastSeen = now
            open.bytes = max(0, sent - open.bytesAtStart)
            openSessions[id] = open
        }
        saveOpenSessions()
    }

    /// Watches whether the screen being streamed can be seen at all, and says so when it cannot.
    ///
    /// The failure is silent by construction: a sleeping display still produces a healthy stream,
    /// frames on time and at full rate, every one of them black, so from the phone it is
    /// indistinguishable from a broken camera.
    ///
    /// Only ever about a display. An application or a window is drawn by the window server whether
    /// or not a panel is lit, so a picture of one is real with every screen dark.
    private func screenNotice() -> NoticePayload? {
        guard case .display(let id)? = capturingSource else { return nil }

        // Gone rather than dark: `online` separates the two. A sleeping display is still connected,
        // while a lid shut with no external screen leaves nothing to have a picture of at all. Both
        // arrive at the phone as black and they are not the same problem, since one is a tap away
        // from fixed and the other needs a different source.
        if CGDisplayIsOnline(id) == 0 {
            return NoticePayload(
                message: "That display is no longer connected. Choose another from Sources.",
                symbol: "display.slash"
            )
        }
        if CGDisplayIsAsleep(id) != 0 || CGDisplayIsActive(id) == 0 {
            return NoticePayload(
                message: "This Mac's screen is asleep.",
                symbol: "moon.zzz.fill"
            )
        }
        return nil
    }

    /// Tells whoever is attached why there is no picture, when the reason is one they cannot see
    /// from where they are.
    ///
    /// The fresh-install failure, and silent on both ends: with Screen Recording not yet allowed,
    /// macOS refuses the stream before a frame exists, so the window goes on saying the Mac is
    /// serving and the phone goes on saying it is opening the video channel. The phone cannot work
    /// it out, since a Mac that cannot capture and one with nothing to show look identical from
    /// there, so the host is the only place the sentence can come from.
    ///
    /// Only for failures with something to say to the far end; ``CaptureError/clientNotice`` decides
    /// which those are. Announced once per problem, not once per attempt, and the record is
    /// per-process on purpose: a grant cannot take effect without a relaunch.
    private func announceCaptureProblem(_ error: CaptureError) {
        guard let notice = error.clientNotice, let message = notice.message else { return }
        guard message != announcedCaptureProblem else { return }
        announcedCaptureProblem = message
        server?.broadcastNotice(notice)
        // The Mac's own activity list gets the line that says the other device was told.
        record("Told the connected device why there is no picture.", level: .warning)
    }

    /// Runs ``screenNotice()`` while anyone is attached.
    ///
    /// Nobody attached means nobody to tell.
    private func startScreenWatch() {
        guard screenWatchTask == nil else { return }
        screenWatchTask = Task { [weak self] in
            var announced: NoticePayload?
            var ticks = 0
            while !Task.isCancelled {
                guard let self else { return }

                // Every thirtieth tick of two seconds, so an abandoned session still has a
                // believable end time and size rather than a zero.
                ticks += 1
                if ticks % 30 == 0 { self.touchOpenSessions() }

                let notice = self.screenNotice()
                if notice != announced {
                    let wasSayingSomething = announced != nil
                    announced = notice
                    self.server?.broadcastNotice(notice ?? NoticePayload(message: nil))
                    if let message = notice?.message {
                        self.record("Screen not visible · \(message)", level: .warning)
                    } else if wasSayingSomething {
                        // It said so when the screen went dark, so it owes the all-clear.
                        self.record("Screen visible again")
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func stopScreenWatch() {
        screenWatchTask?.cancel()
        screenWatchTask = nil
    }

    private func endSession(id: String) {
        guard let open = openSessions.removeValue(forKey: id) else {
            hostLog.notice("session closed for \(id, privacy: .public) with nothing open for it")
            return
        }
        let sent = coordinator?.streamStatistics.bytesSent ?? open.bytesAtStart
        sessions.insert(
            HostSessionRecord(
                deviceName: open.deviceName,
                started: open.started,
                ended: Date(),
                bytes: max(0, sent - open.bytesAtStart)
            ),
            at: 0
        )
        if sessions.count > Self.maxSessions {
            sessions.removeLast(sessions.count - Self.maxSessions)
        }
        saveOpenSessions()
        saveSessions()
        hostLog.notice("session recorded · \(self.sessions.count, privacy: .public) kept")
    }

    // MARK: - Sleep prevention

    /// Toggles what the settings screen calls "Keep Mac awake": the free half of sleep prevention.
    ///
    /// The type is `PreventSystemSleep`, the one `caffeinate -s` acquires, and it stops the Mac
    /// sleeping on its own: idle timers, a stalled download, nothing to do. Closing the lid is a
    /// different path in macOS, and whether the assertion covers it depends on the machine. What
    /// survives a lid close on every Mac is `pmset -a disablesleep 1`, which needs administrator
    /// rights and is the switch below rather than this one.
    ///
    /// Being process-scoped is the property worth having here: the OS releases the assertion when
    /// this process exits, so this switch can never leave a Mac unable to sleep.
    func setPreventLidCloseSleep(_ on: Bool) {
        preventLidCloseSleep = on
        UserDefaults.standard.set(on, forKey: "preventLidCloseSleep")
        if on {
            acquireLidSleepAssertion()
            acquirePreferenceDisplaySleepAssertion()
        } else {
            releaseLidSleepAssertion()
            releasePreferenceDisplaySleepAssertion()
        }
    }

    private func acquireLidSleepAssertion() {
        guard lidSleepAssertionID == 0 else { return }
        let result = IOPMAssertionCreateWithName(
            "PreventSystemSleep" as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "MacCast lid-close sleep prevention" as CFString,
            &lidSleepAssertionID
        )
        if result != kIOReturnSuccess {
            hostLog.notice("could not acquire lid sleep assertion (IOReturn \(result, privacy: .public))")
            record("Could not keep the Mac awake (power assertion \(result))", level: .failure)
        } else {
            record("Keep-awake enabled; macOS does not require a permission prompt", level: .info)
        }
    }

    private func releaseLidSleepAssertion() {
        guard lidSleepAssertionID != 0 else { return }
        IOPMAssertionRelease(lidSleepAssertionID)
        lidSleepAssertionID = 0
    }

    private func acquirePreferenceDisplaySleepAssertion() {
        guard preferenceDisplaySleepAssertionID == 0 else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Peering keep-awake preference" as CFString,
            &preferenceDisplaySleepAssertionID
        )
        if result != kIOReturnSuccess {
            hostLog.notice("could not acquire display sleep assertion (IOReturn \(result, privacy: .public))")
            record("Could not keep the display awake (power assertion \(result))", level: .failure)
        }
    }

    private func releasePreferenceDisplaySleepAssertion() {
        guard preferenceDisplaySleepAssertionID != 0 else { return }
        IOPMAssertionRelease(preferenceDisplaySleepAssertionID)
        preferenceDisplaySleepAssertionID = 0
    }

    // MARK: - Lid-close sleep

    /// Turns "keep running with the lid closed" on or off.
    ///
    /// The switch the assertion above cannot be: the only public setting that survives a closed lid
    /// is `pmset -a disablesleep`, which needs administrator rights and, once set, stays set through
    /// this process, a crash and a reboot. Three things follow from that:
    ///
    /// It is applied through a scoped sudoers rule rather than by prompting every time, so the
    /// password is asked for once. ``LidCloseSleep`` holds the text of that rule and what keeps it
    /// from granting more than the window promises.
    ///
    /// It is undone on the way out (``prepareForTermination()``), because a Mac left unable to sleep
    /// with nothing on screen to explain it is worse than the feature is good.
    ///
    /// And it is re-examined on the way in (``adoptLidCloseSleepSetting()``), because a crash skips
    /// the first of those and the setting survives the crash.
    ///
    /// The stored intention is written only once the machine has actually been changed, so the
    /// switch being on is a statement about the Mac rather than about the last click.
    func setKeepRunningWithLidClosed(_ wanted: Bool) async {
        guard !lidCloseBusy else { return }
        lidCloseBusy = true
        defer {
            lidCloseBusy = false
            // On every exit rather than at each of the six return points, because a switch that
            // moves without its watchdog moving with it either stops being watched or keeps a task
            // alive for nothing.
            updateBatteryWatchdog()
        }
        lidCloseFailure = nil

        // The rule comes first when it is wanted: it is what makes the command below silent, and
        // the only part of this that costs a password.
        if wanted, !(await ensureLidCloseRule()) { return }

        switch await applySleepDisabled(wanted) {
        case .cancelled:
            return
        case .failed(let message):
            lidCloseFailure = message
            record("Could not change lid-close sleep prevention: \(message)", level: .failure)
            return
        case .alreadyThere:
            // The switch follows the intention and the marker does not follow the setting: this app
            // found the Mac like this, so undoing it is not its business, and a marker written here
            // would make the quit path do exactly that.
            keepRunningWithLidClosed = wanted
            UserDefaults.standard.set(wanted, forKey: Self.keepRunningWithLidClosedKey)
            record(wanted
                ? "This Mac was already set to stay up with the lid closed, and not by Peering; it is being left as it was found"
                : "This Mac was already sleeping normally on a closed lid",
                level: .info)
            return
        case .applied:
            break
        }

        // Read after the change rather than assumed from it: the switch is a request and this is
        // what the machine did with it.
        lidCloseSystemState = await LidCloseSleepControl.sleepDisabledState()
        keepRunningWithLidClosed = wanted
        UserDefaults.standard.set(wanted, forKey: Self.keepRunningWithLidClosedKey)
        // The marker records a change this app made to the machine, which is what the quit and
        // launch paths read to know whether undoing it is this app's business.
        UserDefaults.standard.set(wanted, forKey: Self.sleepDisabledByThisAppKey)
        record(wanted
            ? "Lid-close sleep prevention on; this Mac stays up with the lid shut, on battery included"
            : "Lid-close sleep prevention off; this Mac sleeps on a closed lid again")
    }

    /// Watches the charge while the lid-close switch is on, and puts normal sleep back when the
    /// battery gets low.
    private var batteryWatchdog: Task<Void, Never>?

    /// How often the charge is read while the Mac is being kept up.
    ///
    /// A minute against a threshold of ten per cent: finer than it needs to be, and the cost of a
    /// too-fine margin is one small process a minute in the one state where the battery is at risk.
    private static let batteryCheckInterval: TimeInterval = 60

    /// Starts or stops the battery check, to match the switch.
    ///
    /// The rail the other three do not replace: restoring on quit needs the app to be quit, the
    /// launch repair needs it to be launched again, and the switch needs somebody to remember it.
    /// A Mac shut in a bag at ninety per cent has none of those coming.
    private func updateBatteryWatchdog() {
        batteryWatchdog?.cancel()
        batteryWatchdog = nil
        guard keepRunningWithLidClosed else { return }

        batteryWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.batteryCheckInterval))
                guard let self, !Task.isCancelled, self.keepRunningWithLidClosed else { return }

                let state = await LidCloseSleepControl.batteryState()
                guard LidCloseSleep.batteryIsLow(state) else { continue }

                // Turned off through the ordinary path rather than by running `pmset` behind the
                // model's back, so the switch, the marker and the machine all move together and the
                // pane does not go on reading "on" over a Mac allowed to sleep.
                await self.setKeepRunningWithLidClosed(false)
                self.record(
                    "Battery is down to \(LidCloseSleep.batteryFloor)%, so this Mac sleeps normally again. Kept awake with the lid shut it would have run the battery flat rather than sleeping through the last of it.",
                    level: .info
                )
                return
            }
        }
    }

    /// The same thing, under the name the confirmation dialog calls it by.
    func enableLidCloseSleep() async {
        await setKeepRunningWithLidClosed(true)
    }

    /// Reads whether the administrator rule is doing its job.
    ///
    /// Asked of `sudo` rather than of the disk, and re-asked every time the settings pane opens, so
    /// a rule someone removed by hand is what the row ends up describing.
    func checkLidCloseSleepRule() async {
        guard let grants = await LidCloseSleepControl.ruleGrants() else {
            lidCloseRuleInstalled = nil
            return
        }
        lidCloseRuleInstalled = grants.coversBoth
    }

    /// Takes the administrator rule away again, for someone who wants it gone.
    ///
    /// One prompt, and the same prompt undoes the setting: both halves run as root in one shell
    /// script in that order, because the rule is what lets this app turn the setting off later.
    func removeLidCloseRule() async {
        guard !lidCloseBusy else { return }
        lidCloseBusy = true
        defer { lidCloseBusy = false }
        lidCloseFailure = nil

        switch await LidCloseSleepControl.removeRule() {
        case .cancelled:
            return
        case .failed(let message):
            lidCloseFailure = message
            record("Could not remove the administrator sleep rule: \(message)", level: .failure)
        case .done:
            lidCloseRuleInstalled = false
            keepRunningWithLidClosed = false
            UserDefaults.standard.set(false, forKey: Self.keepRunningWithLidClosedKey)
            UserDefaults.standard.set(false, forKey: Self.sleepDisabledByThisAppKey)
            updateBatteryWatchdog()
            record("Administrator sleep rule removed; this Mac sleeps on a closed lid again")
        }
    }

    /// Puts the machine and the switch back into agreement, once, at launch.
    ///
    /// The crash path: a clean quit turns the setting back off and clears the marker, a crash does
    /// neither, and `disablesleep` survives a crash and a reboot, so what this finds is a Mac left
    /// unable to sleep some time ago. The three answers it can reach are in
    /// ``LidCloseSleep/launchAction(systemState:setByThisApp:isPreferred:)``, which is a value with
    /// tests because the mistake worth preventing, undoing a setting somebody else made, cannot be
    /// reproduced on demand by crashing a process.
    func adoptLidCloseSleepSetting() async {
        let state = await LidCloseSleepControl.sleepDisabledState()
        // What the machine is doing, kept so the row can say when it disagrees with the switch: the
        // switch is the intention and this is the reading, and a crash, a force quit or a hand edit
        // puts the two out of step.
        lidCloseSystemState = state

        // Where a claim about a setting that is gone gets dropped. The marker says this app turned
        // the setting on; a reading of `off` says it is not on, whoever did it, so keeping the claim
        // can only do harm: a stale marker plus some other tool later setting `disablesleep` reads
        // as "on, and ours" at the next launch, and the quit path then turns that tool's setting
        // off. Not done on `.unknown`, because forgetting ownership on a failed reading is how a Mac
        // ends up unable to sleep with nothing left claiming it.
        if LidCloseSleep.shouldForgetOwnership(systemState: state) {
            UserDefaults.standard.set(false, forKey: Self.sleepDisabledByThisAppKey)
        }

        // Asked at launch as well as when the Settings pane opens, because the menu bar draws the
        // same switch and is where it is usually flipped from; without it the menu has to guess
        // between a switch that silently fails and a door to a window nobody wanted to open.
        // `sudo -n -l` cannot raise a dialog, so it costs milliseconds and nothing else.
        await checkLidCloseSleepRule()

        let setByThisApp = UserDefaults.standard.bool(forKey: Self.sleepDisabledByThisAppKey)
        switch LidCloseSleep.launchAction(
            systemState: state,
            setByThisApp: setByThisApp,
            isPreferred: keepRunningWithLidClosed
        ) {
        case .keep:
            record("This Mac is still set to stay up with the lid closed")
        case .restore:
            switch LidCloseSleepControl.restoreSleepSilently() {
            case .done:
                UserDefaults.standard.set(false, forKey: Self.sleepDisabledByThisAppKey)
                // Re-read after the change, the way ``setKeepRunningWithLidClosed(_:)`` does: the
                // reading above was taken before this ran and it is the reading the menu draws.
                // Assumed instead of read, a Mac this function has just restored reports itself as
                // still disabled for the rest of the session.
                lidCloseSystemState = await LidCloseSleepControl.sleepDisabledState()
                record("Sleep was still disabled by Peering from a previous run; this Mac sleeps on a closed lid again")
            case .failed(let message):
                lidCloseFailure = message
                // Two sentences rather than one with a description spliced in: the command's own
                // words have no full stop to end them.
                record("This Mac still will not sleep with the lid closed. Switching the row off and on again in Settings is the repair. The command said: \(message)", level: .failure)
            case .cancelled:
                break
            }
        case .reapply:
            switch await LidCloseSleepControl.setSleepDisabled(true) {
            case .done:
                UserDefaults.standard.set(true, forKey: Self.sleepDisabledByThisAppKey)
                // Without this, every launch that re-applies the setting leaves the cached reading
                // at the `.off` that made the re-apply necessary, and the menu says "not in force"
                // over a Mac that is.
                lidCloseSystemState = await LidCloseSleepControl.sleepDisabledState()
                record("Lid-close sleep prevention re-applied; it had been cleared on this Mac since the last run")
            case .failed(let message):
                lidCloseFailure = message
                record("Lid-close sleep prevention is switched on but not in force: \(message)", level: .failure)
            case .cancelled:
                break
            }
        case .leaveAlone:
            // Not ours to undo, and saying so is the point: nothing else in this app can explain why
            // a Mac has stopped sleeping on its lid.
            record("This Mac has sleep disabled and Peering did not do it, so it is being left alone")
        case .none:
            break
        }

        // Reachable after every path above, including the ones that changed nothing: a switch that
        // survived a crash is a Mac that has been up with its lid shut since before this process
        // started, which is when a battery check is most worth having.
        updateBatteryWatchdog()
    }

    /// Puts the rule in place if it is not there, and answers whether it ended up there.
    ///
    /// Checked after installing rather than assumed, and assumed false when `sudo` will not say: the
    /// file is written by another process as root, and the only trustworthy answer about what `sudo`
    /// will do next is `sudo`'s own.
    private func ensureLidCloseRule() async -> Bool {
        // The cache is re-checked before it is trusted. It is filled when the Settings pane opens
        // and the file can be gone since, deleted by hand, removed by the button, or never installed
        // for this account. Trusting it means skipping the install prompt and then failing the very
        // command it was there to make silent, leaving the switch on with nothing behind it and the
        // raw refusal from `sudo` on screen.
        if lidCloseRuleInstalled == true {
            await checkLidCloseSleepRule()
            if lidCloseRuleInstalled == true { return true }
        }

        switch await LidCloseSleepControl.installRule(user: LidCloseSleepControl.invokingUserName) {
        case .cancelled:
            return false
        case .failed(let message):
            lidCloseFailure = message
            record("Could not install the administrator sleep rule: \(message)", level: .failure)
            return false
        case .done:
            await checkLidCloseSleepRule()
            guard lidCloseRuleInstalled == true else {
                lidCloseFailure = "The rule was written, but sudo does not report it. This Mac has not been changed."
                record("The administrator sleep rule was installed but does not take effect", level: .failure)
                return false
            }
            record("Administrator sleep rule installed, granting two pmset commands and nothing else")
            return true
        }
    }

    /// How an attempt to change the machine setting ended, in the four ways it can.
    ///
    /// Four rather than the three ``LidCloseSleepControl/Outcome`` has, because ``alreadyThere``
    /// means the Mac is where it was asked to be and this app did not put it there. That has to be
    /// told apart from a change this app made: the marker that lets it undo its own work on quit
    /// must not be written for somebody else's setting, or the Mac stops sleeping the first time
    /// Peering quits.
    private enum SleepApplication {
        /// This app ran the command and the machine changed.
        case applied
        /// The machine was already in the wanted state, and not because of this app.
        case alreadyThere
        case cancelled
        case failed(String)
    }

    /// Applies the setting, asking for a password only if the silent route has nothing to offer.
    ///
    /// The rule is normally what makes this silent, and it can be gone, deleted by hand or by the
    /// button in Settings. The case that matters then is turning the switch *off*: a Mac whose sleep
    /// is disabled and whose rule has been taken away cannot be put back any other way, and a switch
    /// that will not turn off is worse than one password prompt. The prompt is skipped when the
    /// machine is already where it was asked to be.
    ///
    /// The already-there answer is read before the prompt is considered and never as a success: a
    /// Mac already in the wanted state when the silent command fails has its setting from somewhere
    /// else, and there is nothing for this app to do or to claim.
    private func applySleepDisabled(_ wanted: Bool) async -> SleepApplication {
        let target: LidCloseSleep.SleepDisabledState = wanted ? .on : .off

        // Read before writing, because an exit status cannot tell a change from an agreement:
        // `sudo -n pmset -a disablesleep 1` exits 0 whether it flipped the setting or found it
        // already flipped, and the difference is who owns it. Claiming a setting another tool
        // disabled would make the quit path turn that tool's setting off.
        if await LidCloseSleepControl.sleepDisabledState() == target { return .alreadyThere }

        let outcome = await LidCloseSleepControl.setSleepDisabled(wanted)
        if case .cancelled = outcome { return .cancelled }

        if case .failed(let message) = outcome {
            // The cache is re-read rather than believed here, which is the branch that most needs
            // it: this is where somebody arrives having just deleted the rule by hand, and where
            // turning the switch off is the only thing that can undo a Mac that has stopped
            // sleeping. Believing a stale "the rule is installed" withholds the one password prompt
            // that can still put it back.
            await checkLidCloseSleepRule()
            guard lidCloseRuleInstalled != true else { return .failed(message) }
            return Self.application(of: await LidCloseSleepControl.setSleepDisabledAskingForAdmin(
                wanted,
                prompt: wanted
                    ? "Peering will stop this Mac sleeping with the lid closed."
                    : "Peering will let this Mac sleep normally again."
            ))
        }

        return .applied
    }

    /// The privileged outcome, in the four-way spelling the caller above works in.
    private static func application(of outcome: LidCloseSleepControl.Outcome) -> SleepApplication {
        switch outcome {
        case .done: return .applied
        case .cancelled: return .cancelled
        case .failed(let message): return .failed(message)
        }
    }

    private func acquireSleepAssertion() {
        guard sleepAssertionID == 0 else { return }
        let reason = "MacCast session active" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &sleepAssertionID
        )
        if result != kIOReturnSuccess {
            hostLog.notice("could not acquire sleep assertion (IOReturn \(result, privacy: .public))")
        }
    }

    private func releaseSleepAssertion() {
        guard sleepAssertionID != 0 else { return }
        IOPMAssertionRelease(sleepAssertionID)
        sleepAssertionID = 0
    }

    // MARK: - Device name

    /// The name shown to a client in its device list.
    ///
    /// `Host.current().localizedName` is the "Computer Name" from Sharing settings, which is what
    /// the user recognises. The raw hostname is only a fallback, since a list of those is
    /// unreadable.
    private static var defaultDeviceName: String {
        if let localized = Host.current().localizedName, !localized.isEmpty {
            return localized
        }
        let host = ProcessInfo.processInfo.hostName
        let suffix = ".local"
        return host.hasSuffix(suffix) ? String(host.dropLast(suffix.count)) : host
    }
}
