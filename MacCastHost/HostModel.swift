import AppKit
import Foundation
import IOKit.pwr_mgt
import Observation
import RemoteCore
import WidgetKit
import os

/// Host diagnostics, visible with:
/// `log stream --predicate 'subsystem == "pl.dmq.peering.host"'`
///
/// The window is not always reachable — a headless run, a background launch, a user who
/// cannot see the screen — and every failure mode in this app is silent by nature. Logging
/// to the unified log means "the client connected but nothing happened" is answerable
/// without a debugger.
private let hostLog = Logger(subsystem: "pl.dmq.peering.host", category: "session")

/// Main-actor state for the host window.
///
/// The networking layer knows nothing about SwiftUI and emits ``HostEvent`` values from a
/// background queue; this type is the single place those cross back to the main actor.
/// Keeping that hop in one file means the session state machine never has to reason about
/// actor isolation, and there is exactly one `Task { @MainActor }` to audit rather than a
/// scattering of them.
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

    // Held while at least one client is connected. Released when the last client disconnects.
    // The display stays lit so ScreenCaptureKit does not turn a healthy stream into black frames.
    private var sleepAssertionID: IOPMAssertionID = 0

    // The assertion that keeps the Mac up on its own, with no permission prompt. It is *not* the
    // lid-close switch, whatever its name says: `PreventSystemSleep` is the type `caffeinate -s`
    // takes, and macOS reads a closed lid on a different path entirely. See
    // ``setKeepRunningWithLidClosed(_:)`` for the one that does survive a shut lid, and what it
    // costs, and the `MARK: - Sleep prevention` note below for why this half stayed free.
    private var lidSleepAssertionID: IOPMAssertionID = 0
    private var preferenceDisplaySleepAssertionID: IOPMAssertionID = 0
    private(set) var preventLidCloseSleep: Bool = UserDefaults.standard.bool(forKey: "preventLidCloseSleep")

    /// The key the "keep running with the lid closed" switch is stored under.
    ///
    /// A second switch rather than a stronger version of the one above, because the two are
    /// different promises at different prices: one holds an assertion that costs nothing and dies
    /// with this process, the other changes a machine setting through an administrator rule. One
    /// control for both would take a password for the half that never needed one, and would bury
    /// the price of the half that does.
    private static let keepRunningWithLidClosedKey = "keepRunningWithLidClosed"

    /// The key that records that it was *this app* that ran `pmset -a disablesleep 1`.
    ///
    /// The distinction the whole recovery path rests on. `disablesleep` is a machine setting and
    /// not an assertion: it outlives this process and it outlives a crash, so a host that dies
    /// while this switch is on leaves behind a laptop that will not sleep in a bag. Nothing on the
    /// machine records who set it, so if this app is to undo its own work without undoing somebody
    /// else's, it has to have written the fact down first.
    private static let sleepDisabledByThisAppKey = "sleepDisabledByThisApp"

    /// Whether the user wants this Mac to stay up with its lid shut.
    ///
    /// The intention, not the reading. What the machine is actually doing is `SleepDisabled` in
    /// `pmset -g`, and the two can disagree after a crash, which is what
    /// ``adoptLidCloseSleepSetting()`` exists to repair.
    private(set) var keepRunningWithLidClosed =
        UserDefaults.standard.bool(forKey: HostModel.keepRunningWithLidClosedKey)

    /// Whether `/etc/sudoers.d/peering-sleep` is doing its job, as `sudo` reports it.
    ///
    /// Nil until it has been asked, and nil again when `sudo` will not list at all, which the row
    /// treats as not knowing rather than as not installed: the two lead to different advice, and
    /// only one of them is worth asking for a password over.
    private(set) var lidCloseRuleInstalled: Bool?

    /// Whether an administrator prompt or a process is in flight for that row.
    ///
    /// The switch cannot move until the person in front of the password dialog has answered, and a
    /// control that ignores a click reads as broken, so the row draws this instead of the switch.
    private(set) var lidCloseBusy = false

    /// What went wrong the last time that row was used, until the next attempt.
    private(set) var lidCloseFailure: String?

    /// What `pmset -g` last said, or `nil` before it has been read.
    ///
    /// Kept apart from ``keepRunningWithLidClosed`` because the two answer different questions. That
    /// one is what the user asked for and this one is what the machine is doing, and the whole
    /// reason the recovery code exists is that they come apart: a crash, a force quit, a hand edit
    /// of `/etc/sudoers.d` or somebody else's `pmset` all leave one true and the other false. The
    /// row reads both, so "switched on and not in force" can be said out loud instead of being a
    /// Mac that quietly will not sleep.
    private(set) var lidCloseSystemState: LidCloseSleep.SleepDisabledState?

    /// The one thing this app does before a window exists.
    ///
    /// The lid-close check is here rather than in ``start()``, which runs when the window is
    /// opened, because the Mac this matters on is the one nobody is looking at: it was set to open
    /// at login and left in a corner, with its window closed. The launch that follows a crash is
    /// exactly that launch.
    init() {
        Task { await adoptLidCloseSleepSetting() }
        startResourceSampling()
    }

    /// Whether a given trusted device is attached right now.
    ///
    /// Matched on the ID, which is the only thing the two lists have in common. The name is the
    /// client's to choose, two devices can present the same one, and comparing it against a list
    /// of IDs is a question that is always false — which is how a connected iPhone came to read
    /// as merely "Trusted".
    func isConnected(_ id: String) -> Bool {
        connectedClients.contains { $0.id == id }
    }
    /// Everything the host has said, newest last.
    ///
    /// Kept as entries rather than as formatted lines so the window can show when each thing
    /// happened and which of them went wrong, and can hand the whole list over in one copy.
    private(set) var log: [HostLogEntry] = []

    let permissions = Permissions()

    /// Owned here and driven from two places at once, which is why it is a `@unchecked
    /// Sendable` type with its own lock rather than main-actor state: commands arrive on the
    /// network queue (see the `onCommand` wiring in ``start()``), while the input transform
    /// is written from wherever the coordinator reports one, and the teardown release runs
    /// on the main actor. Hopping either one to the other would put pointer events behind
    /// SwiftUI or the whole UI behind a command queue, so the isolation lives in the type.
    private let input = InputInjector()

    /// Physical display brightness is separate from the captured pixels, which is what lets the
    /// phone keep seeing a Mac whose local panels are dark.
    private let displayPrivacy = DisplayPrivacyController()
    private(set) var privacyModeEnabled = false

    /// The capture source the client last asked for.
    ///
    /// Cleared once the switch has been applied, and deliberately left set when it failed —
    /// a rejected switch means the client and the host now disagree about what is on screen,
    /// and the window is the only place that disagreement can be seen.
    private(set) var pendingCaptureSource: CaptureSource?

    /// What is actually being streamed, once a switch has been applied.
    ///
    /// The answer to the question someone sitting at the Mac asks first: *what can they see?*
    /// ``pendingCaptureSource`` above is the ask rather than the answer — it is cleared on
    /// success and left set on failure, which makes it useful for spotting a disagreement and
    /// useless for saying what is on screen.
    private(set) var capturingSource: CaptureSource?

    /// The last catalogue the resolver built, kept so a source can be named rather than shown
    /// as a number. A ``CaptureSource`` is a display ID or a pid; "DELL P2212H" is the thing a
    /// person recognizes.
    private(set) var catalog: CaptureCatalog?

    /// The display name of what is being captured, if the catalogue can name it.
    var capturingSourceTitle: String? {
        guard let capturingSource, let catalog else { return nil }
        return catalog.all.first { $0.source == capturingSource }?.title
    }

    /// Everything this app has put on the network since it started, picture and sound.
    ///
    /// A counter rather than a rate, because a rate is a subtraction between two readings and
    /// the resources panel is where that subtraction happens: see `ResourceMeter`, which is
    /// where it is tested. `nil` before there is a coordinator at all, which is a different
    /// answer from a coordinator that has sent nothing: the first is "this app is not hosting
    /// yet", the second is a zero the panel can print.
    var streamedBytes: UInt64? {
        guard let stats = coordinator?.streamStatistics else { return nil }
        // The two are counted separately because they are different kinds of traffic, and added
        // here because a user asking what this app sends is asking about the total. Widened on
        // the way out: the streamer counts in `Int`, and a byte count that has reached the
        // panel is a byte count with a sign it does not want.
        return UInt64(max(0, stats.bytesSent + stats.audioBytesSent))
    }

    /// What this app is costing the Mac, for the menu's readings.
    ///
    /// **On the model rather than on the window it used to be read in**, because the menu is where
    /// these are read now and a menu bar app is usually run with its window closed. It is sampled
    /// on a timer from the moment the app launches, which is the one place this differs from the
    /// panel it replaces: that sampled only while its card was on screen, and a menu cannot do the
    /// same thing, because a rate is a difference between two readings — sampling when the menu
    /// opens would show nothing at all the first time and a figure for the interval since the last
    /// time somebody looked on the second.
    ///
    /// The cost of always sampling is the one the sampler's own note describes: two syscalls and
    /// a subtraction every two seconds, next to an encoder that is producing sixty frames of it.
    var resources = HostResourceSampler()

    /// Keeps ``resources`` current. Started once, and never stopped: an app that is not hosting is
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
    /// A trusted device is stored as a pin, and a pin is a public key — there is no name in it.
    /// The name arrives with a connection and is gone when it ends, so without keeping it the
    /// device list can only offer an ID for anything not attached right now, and an ID is not
    /// something anyone recognises as their phone.
    ///
    /// Persisted, because the case this exists for is the device that is *not* here: a list
    /// that only names devices while they are connected has forgotten the name by the time it
    /// is needed.
    private(set) var clientNames: [String: String] =
        UserDefaults.standard.dictionary(forKey: HostModel.clientNamesKey) as? [String: String] ?? [:]

    private static let clientNamesKey = "Peering.clientNames"

    /// What to call a device: its own name if it has ever said one, otherwise its ID.
    func displayName(for clientID: String) -> String {
        clientNames[clientID] ?? clientID
    }

    /// A still of what is being streamed, for the window's preview.
    ///
    /// `nil` when nothing is being captured. That is the honest answer rather than the last
    /// picture taken — a window still showing a frame from ten minutes ago would be claiming
    /// the phone can see something it cannot.
    ///
    /// The caller decides how often to ask, because the caller is the view: a window that is
    /// closed, or behind another one, has no business taking screenshots of this Mac.
    func snapshot(maxWidth: Int = 640) async -> CGImage? {
        await coordinator?.snapshot(maxWidth: maxWidth)
    }

    /// Capture, encode and send. Deliberately not main-actor bound — see ``VideoCoordinator``.
    /// Nil until the first client opens a video connection, because building one touches the
    /// capture catalogue, which needs Screen Recording permission.
    private var coordinator: VideoCoordinator?

    /// Runs while at least one client is attached. See ``startScreenWatch()``.
    private var screenWatchTask: Task<Void, Never>?

    /// The capture problem the attached clients have already been told about.
    ///
    /// Held so the same one is not announced twice. A denied Screen Recording grant fails again
    /// on every attempt to start a stream, and a phone told the same thing four times is a phone
    /// whose notices get ignored. See ``announceCaptureProblem(_:)``.
    private var announcedCaptureProblem: String?

    private var server: HostServer?
    private var relayRegistration: RelayHostRegistration?
    private var nativeTerminalWatcher: NativeTerminalWatcher?
    private var pins: PinStore?
    private var identity: SelfSignedIdentity?
    private var spaceObserver: NSObjectProtocol?

    /// A visible tail of what has happened. Bounded because this is a status window, not a
    /// log viewer, and an unbounded array in `@Observable` state re-renders forever.
    private static let maxEvents = 60

    // MARK: - Port

    private static let portKey = "hostPort"

    /// The port this Mac listens on.
    ///
    /// Read once at launch and written when it changes, because a Mac that needs a different
    /// port needs it every time rather than once. Out of range or unset falls back to the
    /// default, so a bad value in the defaults store cannot leave the host unable to start.
    private static func storedPort() -> UInt16 {
        let stored = UserDefaults.standard.integer(forKey: portKey)
        guard let port = UInt16(exactly: stored), port > 0 else { return ProtocolInfo.defaultPort }
        return port
    }

    /// What the menu bar icon should be showing.
    ///
    /// Computed here rather than in the scene, for the reason the scene already gives: an
    /// `@Observable` read inside `MenuBarExtra`'s label is what invalidates it.
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
    /// Preferred over ``port`` for anything shown to the user: the two are the same while the
    /// listener is up, and while it is down the configured value is a claim about the future.
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
    /// **The restore is why this exists at all now.** `pmset -a disablesleep 1` is a machine
    /// setting: it outlives this process, so a Mac whose owner turned it on and then quit the app
    /// would be a Mac that never sleeps again, with nothing on screen to say why. The restore runs
    /// only when this app is the one that set it, so a machine whose sleep was disabled by
    /// something else is left exactly as it was found; that test, and the marker it reads, are
    /// explained on ``sleepDisabledByThisAppKey``.
    ///
    /// Synchronous, and it stays that way: the process is going away, so there is no later in
    /// which to finish an `await`, and the command it runs either has the right to run or fails in
    /// milliseconds without asking anything. See ``LidCloseSleepControl/restoreSleepSilently()``.
    func prepareForTermination() {
        publishHostWidgetState(listening: false)
        // First, because it is the one thing here that changes the user's Mac in a way they would
        // have to repair from outside this app: everything below is a setting being put back, and
        // this is a monitor being taken away. The window server does collect a virtual display
        // when the process holding it dies (measured on macOS 27, by killing one), but that is an
        // undocumented courtesy of a private API, and the one outcome worth spending a few
        // hundred milliseconds to not depend on.
        removeVirtualDisplay()
        // Cancelled before the restore rather than after, so a check that is already in flight
        // cannot land on a model that is on its way out and put the switch back on.
        batteryWatchdog?.cancel()
        batteryWatchdog = nil
        restoreSleepDisabledIfOurs()
    }

    /// Puts the machine back to sleeping normally, if it was this app that stopped it.
    ///
    /// A failure here leaves the marker in place on purpose: the setting is still on, and the next
    /// launch is the next chance to undo it. The case that produces one is the rule having been
    /// taken away by hand, which is also the case where nothing else could have undone it.
    private func restoreSleepDisabledIfOurs() {
        guard UserDefaults.standard.bool(forKey: Self.sleepDisabledByThisAppKey) else { return }
        switch LidCloseSleepControl.restoreSleepSilently() {
        case .done:
            UserDefaults.standard.set(false, forKey: Self.sleepDisabledByThisAppKey)
        case .failed(let message):
            // Straight to the unified log rather than through ``record(_:level:)``: the window is
            // closing, and an entry appended to a list nobody will read is not a diagnostic.
            hostLog.notice("could not restore lid-close sleep on quit: \(message, privacy: .public)")
        case .cancelled:
            break
        }
    }

    /// Changes the port, and restarts the listener if one is running.
    ///
    /// A restart rather than a rebind, because there is no rebinding: the port is fixed when the
    /// listener is created. It is a heavy way to change one number — the capture stream and every
    /// connected device go with it — but the alternative is a host that reports one port and
    /// listens on another, which is worse in every way that matters.
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

    /// What the picture is made of: how many pixels a frame carries, and how many frames a
    /// second.
    ///
    /// Both are stored the way ``storedPointerSize()`` is, with a value this version cannot
    /// read falling back to the default rather than to the other case — a key written by some
    /// later build must not be able to leave the stream smaller or slower than anyone chose.
    /// The frame rate needs no absence check the way ``storedEnlargePointer()`` does:
    /// `integer(forKey:)` answers 0 for a key that was never written, and 0 is not a rate any
    /// stream can be built at, so the two cases cannot be confused.
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
    /// Not a shortcut, and the rows in the window say as much: a surface's size and its frame
    /// interval are fixed when the `SCStream` is built, so a capture already in flight cannot
    /// be changed — it can only be replaced, which would drop the picture and cost a keyframe
    /// for a setting the user is still deciding on. There is no safe in-place change for these
    /// two properties: both define the capture and encoder timelines.
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
    /// Silent while nothing is listening, which is the ordinary case rather than a failure:
    /// the values live in the stored properties above, and ``start()`` gives a coordinator
    /// built afterwards both of them. Written as one call for that reason — a coordinator
    /// that had been told one half of the pair would build the next stream out of two
    /// different moments.
    private func applyCaptureFormat() {
        coordinator?.setCaptureFormat(resolution: captureResolution, frameRate: captureFrameRate)
    }

    // MARK: - Virtual display

    private static let virtualDisplayKey = "hostVirtualDisplay"

    /// Whether this Mac is showing the phone-shaped display that exists only in software.
    ///
    /// Stored, because it is a change to the user's Mac rather than to a session: the display
    /// comes back at the next launch if it was on at the last one, exactly as the switch says.
    /// There is no case where the switch is on and the display is not: a failed creation turns the
    /// switch back off and says why, because a monitor the user cannot see and a switch that
    /// claims it is there are worse than either on its own.
    private(set) var virtualDisplayEnabled = UserDefaults.standard.bool(forKey: HostModel.virtualDisplayKey)

    /// Why the last attempt failed, if it did, for the row to show.
    private(set) var virtualDisplayFailure: String?

    /// Whether this Mac's system software has the API at all.
    ///
    /// Read by the row so the switch can be offered as off-and-unavailable rather than thrown and
    /// failing, and by ``start()`` so a Mac that never had it does not try at every launch.
    var canShowVirtualDisplay: Bool { VirtualDisplay.isAvailable }

    /// What the virtual display is, which is also the size the row promises.
    var virtualDisplaySize: String {
        "\(Int(VirtualDisplay.phoneShaped.width))×\(Int(VirtualDisplay.phoneShaped.height))"
    }

    /// The display this host made, held for as long as it should exist.
    ///
    /// **The model is the owner, and that is the whole teardown design.** The display goes away
    /// when the last reference to it does, so everything that has to take it down (the switch,
    /// Stop, quitting, and a process that dies without either) comes down to this property
    /// reaching `nil` or the process ending. Keeping it anywhere else (a view, a task, a static)
    /// would be a monitor the user cannot get rid of.
    private var virtualDisplay: VirtualDisplay?

    /// Turns the phone-shaped display on or off, at the user's request.
    ///
    /// Synchronous, and deliberately: the display arrives in well under a second and the row's
    /// switch has to end up where the display actually is, not where it was asked to be. The
    /// only thing that makes this slow enough to notice is the wait for the window server to
    /// take the display, which is bounded at three seconds by ``VirtualDisplay``.
    func setVirtualDisplay(_ wanted: Bool) {
        guard wanted != virtualDisplayEnabled else { return }

        guard wanted else {
            // The switch stays on if the display would not leave, and the row says why. A switch
            // that reads off over a monitor that is still on screen is the one lie this row is
            // arranged to make impossible, and it is the state the user cannot get out of.
            guard removeVirtualDisplay() else { return }
            virtualDisplayFailure = nil
            virtualDisplayEnabled = false
            UserDefaults.standard.set(false, forKey: Self.virtualDisplayKey)
            record("Phone display removed")
            // The catalogue is what the phone's picker is drawn from, and a source that is gone
            // has to leave it as visibly as it arrived.
            coordinator?.refreshCatalog()
            return
        }

        guard canShowVirtualDisplay else {
            let message = "This Mac's system software does not have the virtual display API."
            virtualDisplayFailure = message
            record("Phone display unavailable: \(message)", level: .failure)
            return
        }

        do {
            let display = try VirtualDisplay()
            // Stored before anything else can fail, so a display that is on screen is one the
            // model can always take away again.
            virtualDisplay = display
            virtualDisplayEnabled = true
            virtualDisplayFailure = nil
            UserDefaults.standard.set(true, forKey: Self.virtualDisplayKey)
            record("""
                Phone display on screen as \(display.displayID) · \
                \(virtualDisplaySize) · pick it on the iPhone to arrange windows on
                """)
            coordinator?.refreshCatalog()
        } catch {
            virtualDisplay = nil
            virtualDisplayEnabled = false
            UserDefaults.standard.set(false, forKey: Self.virtualDisplayKey)
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            virtualDisplayFailure = message
            record("Could not make the phone display: \(message)", level: .failure)
        }
    }

    /// Takes the display away before the process does, and reports whether it went.
    ///
    /// Called from the switch, from Stop, and from the termination hook, because a display that
    /// outlives the app is the one failure of this feature the user cannot repair from inside it.
    /// The wait is inside ``VirtualDisplay/remove()``; at quit there is time for it, and the
    /// alternative is a phantom monitor.
    ///
    /// **Kept rather than dropped when it will not leave.** This property is the app's only handle
    /// on the display, so forgetting a display that is still on screen would be forgetting the
    /// monitor the user is looking at, which is the one thing here that cannot be undone.
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
        // There is no useful partial host. Without Screen Recording the client receives no
        // picture; without Accessibility its input is silently discarded. The root onboarding
        // owns requesting both grants and calls back here only when they are actually present.
        guard permissions.allRequiredGranted else {
            status = .idle
            return
        }
        // Before anything opens a session of its own: whatever is in the store at this moment
        // was left by the last process. See ``adoptAbandonedSessions()``.
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
        // pointer is mapped against the display the user is actually looking at. That is a
        // reasonable guess rather than a placeholder: it is exactly right for display
        // capture, which is what a client gets if it never picks a source.
        input.transform = DisplayGeometry.activeTransform()

        // Built here but not started. Constructing a pipeline only stores the resolver —
        // reading the catalogue is what needs permission, and that happens on the first
        // video connection.
        //
        // The resolver is handed an invalidation callback that reaches the coordinator built
        // below it. Going through `self` rather than capturing the coordinator directly is
        // what makes that possible without a placeholder: the callback fires on whatever
        // thread observed the notification, and this is the same main-actor hop every other
        // callback in this method already takes.
        // Re-push the catalog when the user switches Spaces so the client's Space picker
        // updates immediately instead of waiting for the next app launch/quit.
        //
        // This push is about the *number* the picker highlights, which has to follow the user
        // as they move. The picture of the desktop they arrive on is taken by the resolver on
        // its own schedule — it has to wait for the switch to finish on screen — and it pushes
        // a second, updated catalogue once it has one. Neither push can stand in for the other.
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
        // Before any capture can start — the first video connection may arrive seconds from
        // now, and a coordinator that had not been told would build the first stream of the
        // session out of its own defaults and quietly disagree with the window. The setters
        // cannot do this from here: they go through ``applyCaptureFormat()``, which writes to
        // the property below, and this coordinator is not that property yet.
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
            // Written straight through rather than hopped to the main actor: `input` is not
            // UI state, and its `transform` is lock-guarded for exactly this reason.
            guard let transform else { return }
            self?.input.transform = transform
        }
        // The same value, from the only observer that sees it change. For an application or a
        // window this is the authoritative answer — the one above is built from geometry read
        // when capture started, and a window dragged two seconds later has moved since. See
        // ``CapturePipeline/inputTransform()``, which asks the callers to prefer this.
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

        // The server has already established that a live authorized control session holds
        // this client's key — that check is the only thing standing between an open port and
        // the user's screen, and it is not repeated here.
        server.onVideoConnection = { [weak coordinator] peer in
            coordinator?.handleVideoConnection(peer)
        }

        // A client whose picture is not arriving asks for it on the control channel, and that
        // request has to reach the pipeline along with the connection it arrived on. Straight
        // through, off the main actor: deciding it is a question about sockets and an encoder,
        // and hoisting it to the actor that draws the window would only put it behind the
        // window. See ``VideoCoordinator/setVideoTransport(_:clientKey:controlPeer:)``.
        server.onVideoTransport = { [weak coordinator] clientKey, request, controlPeer in
            coordinator?.setVideoTransport(request, clientKey: clientKey, controlPeer: controlPeer)
        }

        // And the same shape for the relay's datagram path: the session's request comes with
        // the client's key and the allocation the relay handed over, and the answer is the
        // secret that seals what goes on it — or nil, which the session turns into silence and
        // the client reads as "the picture stays where it is".
        server.onVideoKeyRequest = { [weak coordinator] clientKey, relay in
            coordinator?.enableVideoDatagrams(clientKey: clientKey, relay: relay)
        }

        // And the picture's on/off switch, which is the same shape once more: straight through,
        // off the main actor, because it is a decision about a socket and an encoder. Nothing
        // here ends a session, so a client that asks for no frames keeps its control channel,
        // its shells and the sleep assertion this Mac holds while it is connected, and only the
        // frames stop. See ``VideoCoordinator/setVideoEnabled(_:clientKey:)``.
        server.onVideoEnabled = { [weak coordinator] clientKey, enabled in
            coordinator?.setVideoEnabled(enabled, clientKey: clientKey)
        }

        // `input` is captured directly rather than reached through `self`, and deliberately
        // so: injecting a mouse move is not UI work, and hopping to the main actor would put
        // every pointer event behind whatever SwiftUI happens to be doing.
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
            if case .switchToSpace(let display, let index) = command {
                Task { @MainActor [weak self] in
                    // The result used to be discarded. `performSwitch` returns whether the
                    // window server *accepted* the move, and that is the whole difference
                    // between a tile that works and one that silently does nothing — the two
                    // are indistinguishable from the phone, and were indistinguishable from
                    // here as well.
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
                // Not hopped to the main actor: the capture is the resolver's own work on its
                // own queue, and the only main-actor thing in it is reading the Space lists,
                // which it does itself. `setStreamQuality` above is the same shape.
                coordinator.refreshSpacePreviews()
                return
            }
            if case .refreshSourceThumbnails = command {
                // The same shape again: the screenshots are taken on the resolver's own tasks
                // and the answer travels on the catalogue push, so nothing here waits.
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
                    // `Q` is keycode 12. 0x19 is `L`, which made the remote lock action
                    // appear to do nothing while the rest of the command path was healthy.
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
            // **A mosaic takes no input, and this is where that is true.** Every other source
            // is something a click can mean on; a canvas is not, because which machine
            // coordinate a point means depends on which tile it landed in, and that is decided
            // by the app rather than posted at the Mac. The client sends nothing while a canvas
            // is up, so this is the belt to that brace: a stray input would otherwise be placed
            // through the last single-source transform, which is a click on a window nobody is
            // looking at. Selecting a tile is an ordinary source switch, and input works again
            // the moment that arrives.
            if command.isUserInput, coordinator.isShowingMosaic {
                return
            }
            input.perform(command)
        }

        // **The reading is asked of the pasteboard rather than of one type on it**, because only
        // this end can find out whether what was copied is a picture or a line of text, and the
        // answer decides how it travels. Both callbacks hop to the main thread: `NSPasteboard` is
        // not safe from anywhere else, and the session's own queue is not it.
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
                for token in server?.allPushTokens() ?? [] {
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

        // Last, deliberately. The display takes a few hundred milliseconds to appear and this
        // waits for it, and nothing above is waiting on the display: a client that connects during
        // those milliseconds is served a catalogue without it and pushed a second one when it
        // arrives, which is the path a display made by hand takes as well.
        restoreVirtualDisplay()
    }

    /// Brings back the phone-shaped display if the switch was on when this Mac was last quit.
    ///
    /// Two lines rather than one because the switch is turned off first: ``setVirtualDisplay(_:)``
    /// refuses a request that matches the state it already believes, and at this point the belief
    /// comes from `UserDefaults` while the display itself is known not to exist. Turning the flag
    /// off first is what makes this a request to *show* the display rather than a no-op, and it
    /// leaves the two in step if that request fails.
    private func restoreVirtualDisplay() {
        guard virtualDisplayEnabled, virtualDisplay == nil else { return }
        virtualDisplayEnabled = false
        setVirtualDisplay(true)
    }

    func stop() {
        // Before the listener goes, while the reason is still on screen. Stopping is the
        // one disconnect that is not the client's doing, so a modifier it was holding when
        // the user pressed Stop is exactly as stuck as one held by a client that crashed.
        // The sessions cancelled below may or may not report a disconnect of their own
        // depending on how far their handshake had got, so this does not wait on them.
        input.releaseAll()
        setPrivacyMode(false)
        // Before the listener goes, and before the process can outlive it: a stopped host that
        // has left a monitor behind is the one state the user cannot repair from the window.
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
    /// The switch happens inside the coordinator: the capture stream is rebuilt for the new
    /// source while the video connection is left alone, so the client sees a new config and
    /// keyframe rather than a reconnect. See ``VideoCoordinator/switchSource(_:)`` for why
    /// the stream is rebuilt instead of having its filter swapped in place. Because the new
    /// source is looked up at switch time, one that has since disappeared fails here rather
    /// than at connection time, which is why the failure names the source.
    private func applyCaptureSource(_ source: CaptureSource) {
        guard let coordinator else {
            // Nothing is being captured, so there is nothing to switch. The request is kept
            // so the window shows what the client last asked for; a client that has not
            // opened a video connection yet will get the default source, not this one.
            record("Capture source requested before any video connection")
            return
        }

        Task { [weak self] in
            do {
                try await coordinator.switchSource(source)
                self?.pendingCaptureSource = nil
                // After the switch rather than before: raising an app whose capture then
                // fails would bring the wrong thing forward and leave it there.
                self?.raiseApplication(for: source)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                self?.record("Could not switch capture source: \(message)", level: .failure)
            }
        }
    }

    /// Brings a captured application to the front, so that what the client sees and where its
    /// clicks land are the same thing.
    ///
    /// Capturing an application is not the same as controlling it, and the gap between the two
    /// is invisible from the client. ScreenCaptureKit composites the app's *windows*; for a
    /// single-window app, `desktopIndependentWindow` captures that window's content exactly, with
    /// no backdrop and no regard for what is drawn over it. So the client sees the app whether it
    /// is occluded, minimised, or on another Space. Input does not work that way: every event goes
    /// to the HID tap, where the window server hit-tests the *real* screen and hands the click to
    /// whatever is genuinely at those coordinates. The user therefore sees the app, clicks where
    /// it appears to be, and hits whatever is actually on top of it — the app looks painted on
    /// rather than present.
    ///
    /// `.activateAllWindows` rather than a plain activation, because ``InputTransform`` for an
    /// application is the union of *every* window it owns: raising only the main one would leave
    /// the transform describing a box that is still partly behind something else.
    ///
    /// The cost is real and worth stating: this moves the app in front of whatever the Mac's own
    /// user was doing, and switches Spaces if its windows are elsewhere. That is what anyone
    /// sitting at the Mac would have to do to use it as well.
    private func raiseApplication(for source: CaptureSource) {
        guard case .application(let pid) = source,
              let running = NSRunningApplication(processIdentifier: pid)
        else { return }

        running.activate(options: [.activateAllWindows])
    }

    /// Opens a GUI application by the bundle identifier offered in the catalogue, then
    /// follows it into application capture. Executable paths never cross the network.
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
            switchToLaunchedApplication(running)
            return
        }

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
                self.switchToLaunchedApplication(application)
            }
        }
    }

    private func switchToLaunchedApplication(_ application: NSRunningApplication) {
        guard let coordinator else {
            record("Application opened; capture is not connected", level: .warning)
            return
        }
        let source = CaptureSource.application(application.processIdentifier)
        pendingCaptureSource = source

        // A launch completion can precede creation of the first capturable window. Poll the
        // observable result instead of assuming that the process being alive means SCK has it.
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
            // The names go with the pins. Keeping them would leave a device list that can name
            // phones it will never let back in, which is a worse answer than not knowing.
            clientNames = [:]
            UserDefaults.standard.removeObject(forKey: Self.clientNamesKey)
            record("All paired clients removed")
        } else {
            record("Could not clear paired clients", level: .failure)
        }
    }

    /// Revokes one phone without disturbing the others.
    ///
    /// Go through the server while it is running so an already-connected phone is disconnected
    /// as well as removed from the Keychain. Before startup there cannot be an active session,
    /// so the store itself is sufficient.
    /// Drops a phone's connection and leaves it trusted.
    ///
    /// Deliberately not forgetful: the pin stays, so the same phone reconnects on its own, and no
    /// pairing code is needed. What it is for is the case where the session should stop *now* —
    /// someone else wants the screen, or the wrong device is attached — and the answer until now
    /// was "Forget", which is a much bigger hammer than the problem.
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
            // Recorded before anything is shown, so the name outlives the connection that
            // carried it. A client may rename itself between sessions, which is why this is
            // assigned rather than only inserted.
            if clientNames[clientID] != clientName {
                clientNames[clientID] = clientName
                UserDefaults.standard.set(clientNames, forKey: Self.clientNamesKey)
            }
            beginSession(id: clientID, name: clientName)
            startScreenWatch()
            record("\(clientName) connected · \(detail)")
            // A client that has just arrived has no source list, so it is sent one now
            // rather than waiting for an application to launch. It is also the first read of
            // the catalogue, which is what needs Screen Recording permission — a refusal
            // here is logged and otherwise ignored, and the video path reports it properly
            // if the client then asks for a source.
            coordinator?.refreshCatalog()
            acquireSleepAssertion()

        case .clientDisconnected(let clientID, let clientName):
            connectedClients.removeAll { $0.id == clientID }
            endSession(id: clientID)
            // The last one out stops the watch. Anybody still attached keeps being told.
            if connectedClients.isEmpty { stopScreenWatch() }
            record("\(clientName) disconnected")
            // The moment nothing is left that can release what this client was holding.
            // A client that dies mid-chord or mid-drag takes its key-up with it, and the
            // Mac would otherwise sit holding ⌘ or a mouse button until a real one arrived
            // from the physical keyboard — see ``InputInjector/releaseAll()``, which is
            // where the reasoning lives. Only on the *last* client: the held state is the
            // Mac's, so releasing it while another client is still connected would drop a
            // modifier that client is holding for real.
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
            // Code intentionally not logged: the unified log is readable by any local process,
            // and the digits are already on screen for the user to compare.
            hostLog.notice("pairing code displayed for \(clientName, privacy: .public)")

        case .pairingCompleted(let clientName, let accepted):
            pairing = nil
            lastOutcome = PairingOutcome(clientName: clientName, accepted: accepted)
            pairedClientIDs = pins?.peerIDs ?? []
            record(accepted ? "Paired with \(clientName)" : "Pairing with \(clientName) rejected")

        case .failed(let message):
            record(message)
            // A failure while listening is worth surfacing as status; a per-connection
            // failure is not, or one bad client would blank out a healthy listener.
            if !status.isListening {
                status = .failed(message)
            }
        }
    }

    private func record(_ message: String, level: HostLogEntry.Level = .info) {
        // `.public` because these lines are the diagnostics, and the one genuinely sensitive
        // value — the pairing code — is already displayed on screen during pairing.
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
    /// Persisted, and bounded: a host that has been running for months should not carry a
    /// year of history around in `UserDefaults` to answer a question about this week.
    private(set) var sessions: [HostSessionRecord] =
        UserDefaults.standard.data(forKey: HostModel.sessionsKey)
            .flatMap { try? JSONDecoder().decode([HostSessionRecord].self, from: $0) } ?? []

    /// A session that has begun and has not been written down as finished.
    ///
    /// Persisted as it goes, which is the whole point: a record written only at the end is
    /// lost whenever the end never arrives — the host is quit, crashes, or is rebuilt while a
    /// phone is attached. Those are exactly the sessions someone would want to look up, and
    /// they were the ones going missing.
    private struct OpenSession: Codable {
        var deviceName: String
        var started: Date
        /// The streamer's byte count when this session began. The count is cumulative and
        /// never reset, so a session's cost is the difference between a later read and this.
        var bytesAtStart: Int
        /// The last moment this session was known to be alive. Becomes its end time if no
        /// end ever arrives, which is the honest answer: it was alive then, and nothing since.
        var lastSeen: Date
        /// Bytes counted as of ``lastSeen``. Kept up to date as the session runs rather than
        /// derived at the end, because for a session that never ends there is no end to derive
        /// it from.
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
    /// Its presence at launch *is* the signal: nothing else clears this store, so if an entry
    /// survives to a fresh process then a phone was attached when the last one ended, and no
    /// disconnect was ever going to arrive for it.
    /// Whether the store has been checked for what the last process abandoned. Once per
    /// process: after that, anything in `openSessions` is one of *our* sessions, running.
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
    /// attached. Written every thirtieth tick rather than every one — this is `UserDefaults`,
    /// and a figure that is half a minute stale is worth more than a write per tick.
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

    /// Watches whether the screen being streamed can be seen at all, and says so when it
    /// cannot.
    ///
    /// The failure this removes is silent by construction. A sleeping display still produces a
    /// perfectly healthy stream — frames on time, at full rate, every one of them black — so
    /// from the phone it is indistinguishable from a broken camera, and there is nothing in
    /// the protocol that said otherwise. `notice` is that missing sentence.
    ///
    /// Only ever about a display. An application or a window is drawn by the window server
    /// whether or not a panel is lit, so a picture of one is real with every screen dark —
    /// which is the case that makes this worth saying only for a display.
    private func screenNotice() -> NoticePayload? {
        guard case .display(let id)? = capturingSource else { return nil }

        // Gone rather than dark. `online` is what separates the two: a sleeping display is
        // still connected, and a lid shut with no external screen attached leaves nothing to
        // have a picture of at all. Both arrive at the phone as black, and they are not the
        // same problem — one is a tap away from fixed, the other needs a different source.
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
    /// **This is the fresh-install failure, and it is silent on both ends.** With Screen Recording
    /// not yet allowed, macOS refuses the stream before a frame exists: this window goes on saying
    /// the Mac is serving, the phone goes on saying it is opening the video channel, and neither
    /// of them ever says the true thing. The phone cannot work it out: from its side a Mac that
    /// cannot capture and a Mac with nothing to show look identical, so the host is the only
    /// place the sentence can come from.
    ///
    /// Only for the failures that have something to say to the far end; ``CaptureError/clientNotice``
    /// decides which those are. Announced once per problem rather than once per attempt, and the
    /// record is per-process on purpose: a grant cannot take effect without a relaunch, so a
    /// problem announced here stays true for the life of this run.
    private func announceCaptureProblem(_ error: CaptureError) {
        guard let notice = error.clientNotice, let message = notice.message else { return }
        guard message != announcedCaptureProblem else { return }
        announcedCaptureProblem = message
        server?.broadcastNotice(notice)
        // The Mac's own activity list gets it too, beside the failure that caused it. It is
        // already recorded there through `apply(.failed(_:))`; this is the line that says the
        // other device was told, which is what an operator reading a report needs to know.
        record("Told the connected device why there is no picture.", level: .warning)
    }

    /// Runs ``screenNotice()`` while anyone is attached.
    ///
    /// Nobody attached means nobody to tell, and a host that checks its own screen every two
    /// seconds to say nothing is a host talking to itself.
    private func startScreenWatch() {
        guard screenWatchTask == nil else { return }
        screenWatchTask = Task { [weak self] in
            var announced: NoticePayload?
            var ticks = 0
            while !Task.isCancelled {
                guard let self else { return }

                // Every thirtieth tick of two seconds, so an abandoned session still has a
                // believable end time and a size rather than a zero.
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
                        // Said so when it went dark, so it owes the all-clear. The warning
                        // above is the one line in this window that resolves itself.
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
    /// **What the assertion does and does not buy, because the name overpromises.** The type is
    /// `PreventSystemSleep`, the one `caffeinate -s` acquires, and it stops the Mac going to sleep
    /// on its own: idle timers, a stalled download, nothing to do. Closing the lid is a *different*
    /// path in macOS, and whether the assertion covers it depends on the machine: a laptop with no
    /// external display in clamshell stays awake on some Macs and sleeps on others. What does
    /// survive a lid close on every Mac is `pmset -a disablesleep 1`, which needs administrator
    /// rights and outlives a crash, and which is the switch below rather than this one.
    ///
    /// The caption on the switch says the same thing in the same words, and the two have to: the
    /// comment that used to be here claimed the assertion survives a lid close on most Macs, which
    /// contradicted the screen the user was reading it on.
    ///
    /// Being process-scoped is the one property worth having on this half: the OS releases the
    /// assertion when this process exits, so the free switch can never leave a Mac unable to
    /// sleep. ``setKeepRunningWithLidClosed(_:)`` buys the same guarantee with a marker, a quit
    /// hook and a launch check, which is most of the reason it is a second switch and not this one
    /// with more force behind it.
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
    /// **The switch the assertion above cannot be.** A closed lid is a separate path in macOS, and
    /// the only public switch that survives one is `pmset -a disablesleep`, which needs
    /// administrator rights and, once set, stays set: through this process, through a crash, and
    /// through a reboot. Three things follow from that, and they are the whole of this section.
    ///
    /// It is applied through a scoped sudoers rule rather than by prompting every time, so the
    /// password is asked for once. ``LidCloseSleep`` holds the text of that rule and the reasons
    /// for its shape, and its tests are what keep it from being a rule that grants more than the
    /// window promises.
    ///
    /// It is undone on the way out, see ``prepareForTermination()``, because a Mac left unable to
    /// sleep with nothing on screen to explain it is a worse outcome than the feature is good.
    ///
    /// And it is re-examined on the way in, see ``adoptLidCloseSleepSetting()``, because a crash
    /// skips the first of those two and the setting survives the crash.
    ///
    /// The stored intention is written only once the machine has actually been changed, so the
    /// switch being on is a statement about the Mac rather than about the last click.
    func setKeepRunningWithLidClosed(_ wanted: Bool) async {
        guard !lidCloseBusy else { return }
        lidCloseBusy = true
        defer {
            lidCloseBusy = false
            // Started or stopped on every exit from this function rather than at each of its six
            // return points, because a switch that moves without its watchdog moving with it is a
            // Mac that either stops being watched or keeps a task alive for nothing.
            updateBatteryWatchdog()
        }
        lidCloseFailure = nil

        // The rule comes first when it is wanted: it is what makes the command below silent, and
        // it is the only part of this that costs a password.
        if wanted, !(await ensureLidCloseRule()) { return }

        switch await applySleepDisabled(wanted) {
        case .cancelled:
            return
        case .failed(let message):
            lidCloseFailure = message
            record("Could not change lid-close sleep prevention: \(message)", level: .failure)
            return
        case .alreadyThere:
            // The switch follows the intention and the marker does not follow the setting, which is
            // the whole of the difference between adopting a setting and stealing one: this app
            // found the Mac like this, so undoing it is not its business, and the quit path would
            // otherwise do exactly that.
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

        // Read after the change rather than assumed from it, for the reason the whole section
        // exists: the switch is a request and this is what the machine did with it.
        lidCloseSystemState = await LidCloseSleepControl.sleepDisabledState()
        keepRunningWithLidClosed = wanted
        UserDefaults.standard.set(wanted, forKey: Self.keepRunningWithLidClosedKey)
        // The marker is this app's record of a change it made to the machine, and it is what the
        // quit and launch paths use to know whether undoing that change is this app's business.
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
    /// A minute, against a threshold of ten per cent. At the draw of a Mac running with its screen
    /// off that is a good deal finer than it needs to be, and the cost of the margin being too fine
    /// is one small process a minute in the one state where the battery is at risk.
    private static let batteryCheckInterval: TimeInterval = 60

    /// Starts or stops the battery check, to match the switch.
    ///
    /// **The rail the other three do not replace.** Restoring on quit needs the app to be quit, the
    /// launch repair needs it to be launched again, and the switch needs somebody to remember it.
    /// A Mac shut in a bag at ninety per cent has none of those coming, and what it has instead is
    /// this: a check that runs while the machine is on its way down and takes the decision out of
    /// the hands of somebody who is not there.
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
                // pane does not go on reading "on" over a Mac that has been allowed to sleep.
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
    /// Asked of `sudo` rather than of the disk, see ``LidCloseSleep/grants(inSudoListing:)``, and
    /// asked again every time the settings pane is opened rather than once at launch, so that a
    /// rule someone removed by hand in another window is what the row ends up describing.
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
    /// script, in that order, because the rule is what lets this app turn the setting off later.
    /// See ``LidCloseSleep/removeScript()``.
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
    /// **The crash path, and the reason it is a decision rather than a line of code.** A clean quit
    /// turns the setting back off and clears the marker. A crash does neither, and `disablesleep`
    /// survives a crash and a reboot, so what this finds is a Mac that was left unable to sleep
    /// some time ago. The three answers it can reach are in
    /// ``LidCloseSleep/launchAction(systemState:setByThisApp:isPreferred:)``, which is a value with
    /// tests because the mistake worth preventing, undoing a setting somebody else made, cannot be
    /// reproduced on demand by crashing a process.
    func adoptLidCloseSleepSetting() async {
        let state = await LidCloseSleepControl.sleepDisabledState()
        // What the machine is doing, kept so the row can say when it disagrees with the switch. The
        // switch is the intention and this is the reading, and the two come apart after a crash, a
        // force quit or a hand edit. That disagreement used to be visible only as a red line inside
        // the Settings pane for one session, so a Mac that had stopped sleeping looked exactly like
        // a Mac that had not.
        lidCloseSystemState = state

        // **Where a claim about a setting that is gone gets dropped.** The marker says this app
        // turned the setting on; a reading of `off` says it is not on, whoever did it, so the claim
        // is stale and only harm can come of keeping it. Harm with a concrete shape: a stale marker
        // plus some other tool later setting `disablesleep` reads as "on, and ours" at the next
        // launch, and the quit path then turns that tool's setting off. Not done on `.unknown`,
        // because forgetting ownership on a reading that failed is how a Mac ends up unable to
        // sleep with nothing left claiming it.
        if LidCloseSleep.shouldForgetOwnership(systemState: state) {
            UserDefaults.standard.set(false, forKey: Self.sleepDisabledByThisAppKey)
        }

        // Asked once at launch as well as when the Settings pane opens, because the menu bar draws
        // the same switch and is the place it is usually flipped from. Without this the menu would
        // have to guess, and its options are a switch that silently fails or a door to a window
        // somebody did not want to open. `sudo -n -l` cannot raise a dialog, so it costs
        // milliseconds and nothing else.
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
                // Re-read after the change, the way ``setKeepRunningWithLidClosed(_:)`` does and
                // for the same reason: the reading above was taken before this ran, and it is the
                // reading the menu draws. Assumed instead of read, a Mac this function has just
                // put back under the setting reports itself as not under it for the rest of the
                // session, which is the one line the menu must never get wrong.
                lidCloseSystemState = await LidCloseSleepControl.sleepDisabledState()
                record("Sleep was still disabled by Peering from a previous run; this Mac sleeps on a closed lid again")
            case .failed(let message):
                lidCloseFailure = message
                // Two sentences rather than one with a description spliced into it: the command's
                // own words have no full stop to end them, so the second sentence used to arrive
                // welded onto the first.
                record("This Mac still will not sleep with the lid closed. Switching the row off and on again in Settings is the repair. The command said: \(message)", level: .failure)
            case .cancelled:
                break
            }
        case .reapply:
            switch await LidCloseSleepControl.setSleepDisabled(true) {
            case .done:
                UserDefaults.standard.set(true, forKey: Self.sleepDisabledByThisAppKey)
                // The path this whole reading exists for: without it, every launch that re-applies
                // the setting leaves the cached reading at the `.off` that made the re-apply
                // necessary, and the menu says "not in force" over a Mac that is.
                lidCloseSystemState = await LidCloseSleepControl.sleepDisabledState()
                record("Lid-close sleep prevention re-applied; it had been cleared on this Mac since the last run")
            case .failed(let message):
                lidCloseFailure = message
                record("Lid-close sleep prevention is switched on but not in force: \(message)", level: .failure)
            case .cancelled:
                break
            }
        case .leaveAlone:
            // Not ours to undo, and saying so is the point: nothing else in this app can explain
            // why a Mac has stopped sleeping on its lid.
            record("This Mac has sleep disabled and Peering did not do it, so it is being left alone")
        case .none:
            break
        }

        // Reachable after every path above, including the ones that changed nothing: a switch that
        // survived a crash is a Mac that has been up with its lid shut since before this process
        // started, which is exactly when a battery check is most worth having.
        updateBatteryWatchdog()
    }

    /// Puts the rule in place if it is not there, and answers whether it ended up there.
    ///
    /// Checked after installing rather than assumed, and assumed to be false when `sudo` will not
    /// say: the file is written by another process, as root, and the only trustworthy answer about
    /// what `sudo` will do next is `sudo`'s own.
    private func ensureLidCloseRule() async -> Bool {
        // **The cache is re-checked before it is trusted, and the re-check is what makes the switch
        // work at all.** It is filled when the Settings pane opens, and the file can be gone since:
        // deleted by hand, removed by the button, or never installed for this account. Trusting it
        // means skipping the install prompt and then failing the very command it was there to make
        // silent, which leaves the switch on with nothing behind it and the raw refusal from `sudo`
        // on screen. `sudo -n -l` cannot put a dialog up, so asking again costs milliseconds.
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
    /// Four rather than the three ``LidCloseSleepControl/Outcome`` has, because the fourth is not
    /// like the others: ``alreadyThere`` means the Mac is where it was asked to be and *this app did
    /// not put it there*. That has to be told apart from a change this app made, because the marker
    /// that lets it undo its own work on quit must not be written for a setting that is somebody
    /// else's. A Mac whose clamshell setting is held by another tool and whose marker says
    /// otherwise is a Mac that stops sleeping the first time Peering quits.
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
    /// The rule is normally what makes this silent. It can be gone, deleted by hand or by the
    /// button in Settings, and the case that matters then is turning the switch *off*: a Mac whose
    /// sleep is disabled and whose rule has been taken away cannot be put back any other way, and
    /// a switch that will not turn off is worse than one password prompt. The prompt is skipped
    /// when the machine is already where it was asked to be, which is what makes switching off a
    /// Mac that sleeps normally cost nothing at all.
    ///
    /// **The already-there answer is read before the prompt is considered, and never as a
    /// success.** A Mac that is already in the wanted state when the silent command fails is a Mac
    /// whose setting comes from somewhere else: another tool's sudoers rule, or somebody typing
    /// `pmset` themselves. There is nothing for this app to do and nothing for it to claim.
    private func applySleepDisabled(_ wanted: Bool) async -> SleepApplication {
        let target: LidCloseSleep.SleepDisabledState = wanted ? .on : .off

        // **Read before writing, because an exit status cannot tell a change from an agreement.**
        // `sudo -n pmset -a disablesleep 1` exits 0 whether it flipped the setting or found it
        // already flipped, and the difference is the whole of who owns it: a Mac whose clamshell
        // sleep another tool had already disabled would be claimed by this app, and the quit path
        // would then turn that other tool's setting off. Asking the machine first costs one process
        // more than the command itself and it is the only thing that separates the two cases.
        if await LidCloseSleepControl.sleepDisabledState() == target { return .alreadyThere }

        let outcome = await LidCloseSleepControl.setSleepDisabled(wanted)
        if case .cancelled = outcome { return .cancelled }

        if case .failed(let message) = outcome {
            // **The cache is re-read rather than believed here, and this is the branch that most
            // needs it.** It is where somebody arrives having just deleted the rule by hand, and
            // where turning the switch off is the only thing that can undo a Mac that has stopped
            // sleeping. Believing a stale "the rule is installed" is what withholds the one
            // password prompt that can still put it back.
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
    /// `Host.current().localizedName` is the "Computer Name" from Sharing settings —
    /// "Damian's MacBook Pro" — which is what the user actually recognises. The raw
    /// hostname (`damians-macbook-pro`) is only a fallback: it is what Bonjour would
    /// advertise by default, and a list of those is unreadable.
    private static var defaultDeviceName: String {
        if let localized = Host.current().localizedName, !localized.isEmpty {
            return localized
        }
        let host = ProcessInfo.processInfo.hostName
        let suffix = ".local"
        return host.hasSuffix(suffix) ? String(host.dropLast(suffix.count)) : host
    }
}
