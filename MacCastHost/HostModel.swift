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

    var status: Status = .idle {
        didSet { publishHostWidgetState() }
    }
    var deviceName = "" {
        didSet { publishHostWidgetState() }
    }
    var deviceID = ""

    /// Present only while a first-time pairing is waiting on the user's comparison.
    var pairing: PairingPrompt?
    var lastOutcome: PairingOutcome?

    var connectedClients: [ConnectedClient] = [] {
        didSet { publishHostWidgetState() }
    }
    var pairedClientIDs: [String] = []

    // Held while at least one client is connected, released when the last one disconnects: the
    // display stays lit so ScreenCaptureKit does not turn a healthy stream into black frames.
    var sleepAssertionID: IOPMAssertionID = 0

    // The assertion that keeps the Mac up on its own, with no permission prompt. It is not the
    // lid-close switch, whatever the name says: `PreventSystemSleep` is what `caffeinate -s` takes,
    // and macOS reads a closed lid on a different path. See ``setKeepRunningWithLidClosed(_:)``.
    var lidSleepAssertionID: IOPMAssertionID = 0
    var preferenceDisplaySleepAssertionID: IOPMAssertionID = 0
    var preventLidCloseSleep: Bool = UserDefaults.standard.bool(forKey: "preventLidCloseSleep")

    /// Whether the user wants this Mac to stay up with its lid shut.
    ///
    /// The intention, not the reading. What the machine is doing is `SleepDisabled` in `pmset -g`,
    /// and the two disagree after a crash, which ``adoptLidCloseSleepSetting()`` repairs.
    var keepRunningWithLidClosed =
        UserDefaults.standard.bool(forKey: HostModel.keepRunningWithLidClosedKey)

    /// Whether `/etc/sudoers.d/peering-sleep` is doing its job, as `sudo` reports it.
    ///
    /// Nil until it has been asked, and nil again when `sudo` will not list at all, which the row
    /// treats as not knowing rather than as not installed: the two lead to different advice.
    var lidCloseRuleInstalled: Bool?

    /// Whether an administrator prompt or a process is in flight for that row.
    ///
    /// The switch cannot move until the person at the password dialog has answered, and a control
    /// that ignores a click reads as broken, so the row draws this instead.
    var lidCloseBusy = false

    /// What went wrong the last time that row was used, until the next attempt.
    var lidCloseFailure: String?

    /// What `pmset -g` last said, or `nil` before it has been read.
    ///
    /// Kept apart from ``keepRunningWithLidClosed``, which is what the user asked for. The two come
    /// apart after a crash, a force quit, a hand edit of `/etc/sudoers.d` or somebody else's
    /// `pmset`, and the row reads both so "switched on and not in force" can be said out loud.
    var lidCloseSystemState: LidCloseSleep.SleepDisabledState?

    /// Whether the Mac is kept awake only inside a window of the day.
    ///
    /// **The switches above have no idea whether anybody is using the Mac.** Left on they hold a
    /// laptop awake on a desk, overnight, indefinitely, which is not what anybody means by "keep
    /// this Mac reachable" — it is what they discover a week later when the battery has been
    /// through a few hundred cycles. This is the half that has an opinion about *when*.
    var keepAwakeScheduleEnabled =
        UserDefaults.standard.bool(forKey: HostModel.keepAwakeScheduleEnabledKey)

    /// The window's first hour, 0-23, inclusive.
    var keepAwakeStartHour =
        UserDefaults.standard.object(forKey: HostModel.keepAwakeScheduleStartHourKey) as? Int
            ?? HostModel.keepAwakeDefaultStartHour

    /// The window's last hour, 0-23, exclusive. Lower than the start means the window crosses
    /// midnight.
    var keepAwakeEndHour =
        UserDefaults.standard.object(forKey: HostModel.keepAwakeScheduleEndHourKey) as? Int
            ?? HostModel.keepAwakeDefaultEndHour

    /// Whether a keep-awake the user asked for is deliberately not in force at the moment, either
    /// because the schedule's window is shut or because they let it go by hand.
    ///
    /// **Kept because the pane has to be able to tell the two apart.** A Mac that something
    /// deliberately released and a Mac whose `pmset` setting somebody removed by hand look
    /// identical from the switch, and the second one is the state the whole recovery path exists
    /// for: it is the one where the app is claiming to hold the Mac up and is not.
    var keepAwakeWithheld = false

    /// The clock behind the schedule. One minute, because the thing it moves is an hour wide.
    var keepAwakeScheduleTask: Task<Void, Never>?

    /// Set when the user answered the prompt by letting the Mac go by hand.
    ///
    /// **Its own flag rather than a release, because the release would be undone within a minute.**
    /// The schedule re-applies on a clock, and inside its window that means putting back everything
    /// the switches ask for, including whatever the user has just said no to. This is what makes the
    /// answer stick until something says the situation has changed: a client connecting, or one of
    /// the switches being touched.
    var keepAwakeReleasedByHand = false

    /// The hour this Mac is woken every day, or `nil` when it is not.
    ///
    /// **The half of the schedule that macOS does for us.** Letting the Mac go at night is only
    /// useful if something brings it back, and a sleeping Mac cannot start its own timer. `pmset`
    /// writes the wake into the machine's own schedule, which fires with nothing running and
    /// nothing on the network: wake-on-LAN is a broadcast to a LAN, and a phone arriving over the
    /// relay is not on one.
    var wakeScheduleHour: Int? =
        UserDefaults.standard.object(forKey: HostModel.wakeScheduleHourKey) as? Int

    /// Whether an administrator prompt is in flight for that row.
    var wakeScheduleBusy = false
    var wakeScheduleFailure: String?

    /// What `pmset -g sched` lists that is not one of the system's own alarms.
    ///
    /// Read rather than assumed, because `pmset` allows one repeating pair and setting ours
    /// replaces whatever was there. Shown before it is replaced rather than after.
    var otherScheduledEvents: [String] = []

    /// The system's own idle-sleep timer, in minutes, with `0` meaning never.
    var idleSleepMinutes: Int?

    /// The wait between the last client leaving and the question being asked. See
    /// ``scheduleKeepAwakePrompt()`` for why it is not asked on the instant.
    var keepAwakePromptTask: Task<Void, Never>?

    /// Asked when the last client goes, and the one prompt this feature has.
    ///
    /// Set rather than shown directly so the pane can raise it: a model that put a dialog up would
    /// be a dialog from a background thread, and on a Mac with no window open it would be a dialog
    /// from nowhere.
    var asksToReleaseKeepAwake = false

    /// The one thing this app does before a window exists.
    ///
    /// The lid-close check is here rather than in ``start()``, which runs when the window opens,
    /// because the Mac this matters on is the one nobody is looking at: set to open at login, left
    /// in a corner with its window closed. The launch after a crash is exactly that launch.
    init() {
        Task { await adoptLidCloseSleepSetting() }
        startResourceSampling()
        // The window may have opened and closed long before anybody looked at it, and this Mac was
        // launched at login for exactly that case: without the clock started here, a Mac restarted
        // inside its own window would sit with the schedule off until somebody opened the pane.
        updateKeepAwakeScheduleWatch()
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
    var log: [HostLogEntry] = []

    let permissions = Permissions()

    /// Driven from two places at once, which is why it is `@unchecked Sendable` with its own lock
    /// rather than main-actor state: commands arrive on the network queue (see the `onCommand`
    /// wiring in ``start()``), the input transform is written from wherever the coordinator reports
    /// one, and the teardown release runs on the main actor. Hopping either to the other would put
    /// pointer events behind SwiftUI or the UI behind a command queue.
    let input = InputInjector()

    /// Physical display brightness is separate from the captured pixels, which is what lets the
    /// phone keep seeing a Mac whose local panels are dark.
    let displayPrivacy = DisplayPrivacyController()

    /// The other half of the same feature: a black cover over every display the brightness pass
    /// above will not touch, which is the whole of what a third-party monitor gets.
    let privacyCurtain = DisplayPrivacyCurtain()

    /// Set while Privacy Mode is on, so a display attached mid-session gets covered too.
    var displayObserver: NSObjectProtocol?
    var privacyModeEnabled = false

    /// The capture source the client last asked for.
    ///
    /// Cleared once the switch has been applied, and deliberately left set when it failed: a
    /// rejected switch means the client and the host disagree about what is on screen, and the
    /// window is the only place that disagreement can be seen.
    var pendingCaptureSource: CaptureSource?

    /// What is actually being streamed, once a switch has been applied.
    ///
    /// ``pendingCaptureSource`` above is the ask rather than the answer, cleared on success and
    /// left set on failure, which makes it useful for spotting a disagreement and useless for
    /// saying what is on screen.
    var capturingSource: CaptureSource?

    /// The last catalogue the resolver built, kept so a source can be named rather than shown as a
    /// number: a ``CaptureSource`` is a display ID or a pid, and "DELL P2212H" is what a person
    /// recognizes.
    var catalog: CaptureCatalog?

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
    func startResourceSampling() {
        Task { @MainActor [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                if tick % 10 == 0 { resources.sample(bytesSent: streamedBytes ?? 0) }
                let open = coordinator?.isDirectPathOpen ?? false
                if directPathOpen != open { directPathOpen = open }
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Whether the served relayed client's video has found its way around the relay.
    var directPathOpen = false

    /// The last name each device gave when it connected.
    ///
    /// A pin is a public key and carries no name, and the name arrives with a connection and goes
    /// when it ends, so without keeping it the device list can only offer an ID for anything not
    /// attached right now. Persisted, because the case this is for is the device that is *not* here.
    var clientNames: [String: String] =
        UserDefaults.standard.dictionary(forKey: HostModel.clientNamesKey) as? [String: String] ?? [:]

    static let clientNamesKey = "Peering.clientNames"

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
    /// Written only from ``start()`` and ``stop()``; every other `HostModel+*.swift` file only
    /// reads it.
    var coordinator: VideoCoordinator?

    /// Runs while at least one client is attached. See ``HostModel/startScreenWatch()``.
    var screenWatchTask: Task<Void, Never>?
    @ObservationIgnored let textFocusWatcher = TextFocusWatcher()

    /// The capture problem the attached clients have already been told about.
    ///
    /// Held so the same one is not announced twice: a denied Screen Recording grant fails again on
    /// every attempt to start a stream, and a phone told the same thing four times ignores it.
    var announcedCaptureProblem: String?

    /// Written only from ``start()`` and ``stop()``; ``HostModel+Sessions.swift`` only reads it.
    var server: HostServer?
    var relayRegistration: RelayHostRegistration?

    /// What the test button in Settings last had to say, shown beside it.
    ///
    /// Only half the answer to "does this work at all": a registered token means a phone handed one
    /// over while a session was up, and whether the relay then reached APNs is not visible from this
    /// Mac at any price, since the relay holds the key and answers nothing.
    var pushTestResult: String?

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
    var nativeTerminalWatcher: NativeTerminalWatcher?
    var pins: PinStore?
    var identity: SelfSignedIdentity?
    var spaceObserver: NSObjectProtocol?

    /// A visible tail of what has happened. Bounded because this is a status window, not a log
    /// viewer, and an unbounded array in `@Observable` state re-renders forever.
    static let maxEvents = 60

    /// What the host is configured to listen on, whether or not it currently is. See
    /// ``HostModel+Port.swift``.
    var port: UInt16 = HostModel.storedPort()

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
        virtualDisplayTeardownDepth += 1
        publishHostWidgetState(listening: false)
        // First, because it is the one thing here that changes the user's Mac in a way they would
        // have to repair from outside this app: everything below is a setting being put back, this
        // is a monitor being taken away. The window server does collect a virtual display when the
        // process dies, but that is an undocumented courtesy of a private API and not worth
        // depending on.
        virtualDisplayCreationGeneration &+= 1
        removeAllManagedVirtualDisplays()
        // Cancelled before the restore rather than after, so a check already in flight cannot land
        // on a model that is on its way out and put the switch back on.
        batteryWatchdog?.cancel()
        batteryWatchdog = nil
        restoreSleepDisabledIfOurs()
    }

    // MARK: - Capture

    /// What the picture is made of: how many pixels a frame carries, and how many frames a second.
    /// Setters and the persisted defaults live in ``HostModel+Capture.swift``.
    var captureResolution: CaptureResolution = HostModel.storedCaptureResolution()
    var captureFrameRate: CaptureFrameRate = HostModel.storedCaptureFrameRate()
    var captureCodec: VideoCodec = HostModel.storedCaptureCodec()

    // MARK: - Virtual display

    /// Displays made at the phone's request, over ``RemoteCommand/addVirtualDisplay(name:)``.
    ///
    /// **The only way one of these exists.** There used to be a second store beside this one for a
    /// display the Mac's own switch made, free on every plan and restored at launch; creation is the
    /// phone's alone now, and a display nobody asked for is a screen the Mac's user did not make and
    /// cannot take away from the app that did. These are session-scoped: they go when the client
    /// that asked for them does. See `HostModel+VirtualDisplayManagement.swift`.
    var managedVirtualDisplays: [VirtualDisplay] = []

    /// The next serial number a phone-requested display gets.
    ///
    /// The management path derives a distinct product from this number too: the window server
    /// accepted serial-only identities but reset all their modes to 800×600. Only ever counts up: a
    /// display that was removed does not give its serial back, which costs nothing against a
    /// `UInt32` and avoids a reused serial racing the window server's own teardown of the display
    /// that just gave it up.
    var nextManagedVirtualDisplaySerial: UInt32 = 1

    /// Changes whenever teardown invalidates a virtual display currently being constructed.
    /// `VirtualDisplay.init` turns the main run loop, so Stop or Quit can run in the middle of the
    /// call; the creator compares this value before retaining what it made.
    var virtualDisplayCreationGeneration: UInt64 = 0

    /// Nesting depth while Stop/Quit is walking the display collection. Private display waits turn
    /// the main run loop, so one teardown can begin inside another; a depth keeps the outer barrier
    /// raised when the inner call returns.
    var virtualDisplayTeardownDepth = 0
    var isTearingDownVirtualDisplays: Bool { virtualDisplayTeardownDepth > 0 }

    /// Whether the virtual-display collection is being changed right now.
    ///
    /// The wait inside ``VirtualDisplay`` turns the main run loop, so a second click can arrive
    /// while the first display is still being made. Removal can await a capture handoff too. A
    /// second add/remove (or the Mac switch) is dropped during either window so a limit check and a
    /// fallback choice cannot be invalidated by another mutation landing in the middle.
    var isMakingVirtualDisplay = false

    /// The whole log as text, for the window's copy button.
    var logText: String { log.plainText }

    /// Finished sessions, newest first.
    ///
    /// Persisted and bounded: a host running for months should not carry a year of history in
    /// `UserDefaults` to answer a question about this week. Read and written from
    /// ``HostModel+Sessions.swift``.
    var sessions: [HostSessionRecord] =
        UserDefaults.standard.data(forKey: HostModel.sessionsKey)
            .flatMap { try? JSONDecoder().decode([HostSessionRecord].self, from: $0) }
            .map { Array($0.prefix(HostModel.maxSessions)) } ?? []

    /// Sessions in flight, by client ID — more than one phone can be attached at once. See
    /// ``HostModel/OpenSession``.
    var openSessions: [String: OpenSession] =
        UserDefaults.standard.data(forKey: HostModel.openSessionsKey)
            .flatMap { try? JSONDecoder().decode([String: OpenSession].self, from: $0) } ?? [:]

    /// Whether the store has been checked for what the last process abandoned. Once per process:
    /// after that, anything in ``openSessions`` is one of ours, running.
    var hasAdoptedAbandonedSessions = false

    // MARK: - Sleep prevention

    /// Watches the charge while the lid-close switch is on, and puts normal sleep back when the
    /// battery gets low. Started and stopped from ``HostModel+SleepPrevention.swift``.
    var batteryWatchdog: Task<Void, Never>?

    // MARK: - Device name

    /// The name shown to a client in its device list.
    ///
    /// `Host.current().localizedName` is the "Computer Name" from Sharing settings, which is what
    /// the user recognises. The raw hostname is only a fallback, since a list of those is
    /// unreadable.
    static var defaultDeviceName: String {
        if let localized = Host.current().localizedName, !localized.isEmpty {
            return localized
        }
        let host = ProcessInfo.processInfo.hostName
        let suffix = ".local"
        return host.hasSuffix(suffix) ? String(host.dropLast(suffix.count)) : host
    }
}
