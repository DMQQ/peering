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
private let hostLog = Logger(subsystem: "pl.dmq.peering.host", category: "session")

/// The single place HostEvent values cross from the network queue to the main actor.
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

    var pairing: PairingPrompt?
    var lastOutcome: PairingOutcome?

    var connectedClients: [ConnectedClient] = [] {
        didSet { publishHostWidgetState() }
    }
    var pairedClientIDs: [String] = []

    // Held while at least one client is connected, released when the last one disconnects: the
    // display stays lit so ScreenCaptureKit does not turn a healthy stream into black frames.
    var sleepAssertionID: IOPMAssertionID = 0

    var agentSleepAssertionID: IOPMAssertionID = 0

    // The assertion that keeps the Mac up on its own, with no permission prompt. It is not the
    // lid-close switch, whatever the name says: `PreventSystemSleep` is what `caffeinate -s` takes,
    // and macOS reads a closed lid on a different path. See ``setKeepRunningWithLidClosed(_:)``.
    var lidSleepAssertionID: IOPMAssertionID = 0
    var preferenceDisplaySleepAssertionID: IOPMAssertionID = 0
    var preventLidCloseSleep: Bool = UserDefaults.standard.bool(forKey: "preventLidCloseSleep")

    /// The intention, not the reading: SleepDisabled in pmset -g can disagree after a crash (see adoptLidCloseSleepSetting()).
    var keepRunningWithLidClosed =
        UserDefaults.standard.bool(forKey: HostModel.keepRunningWithLidClosedKey)

    /// nil when unasked or when sudo will not list, which the row treats as not knowing rather than not installed.
    var lidCloseRuleInstalled: Bool?

    var lidCloseBusy = false

    var lidCloseFailure: String?

    /// Kept apart from keepRunningWithLidClosed (what was asked): they diverge after a crash, force quit or an outside pmset.
    var lidCloseSystemState: LidCloseSleep.SleepDisabledState?

    /// The switches above do not know whether anybody is using the Mac, so left on they hold a laptop awake indefinitely; this adds the when.
    var keepAwakeScheduleEnabled =
        UserDefaults.standard.bool(forKey: HostModel.keepAwakeScheduleEnabledKey)

    var keepAwakeStartHour =
        UserDefaults.standard.object(forKey: HostModel.keepAwakeScheduleStartHourKey) as? Int
            ?? HostModel.keepAwakeDefaultStartHour

    /// The window's last hour, 0-23, exclusive. Lower than the start means the window crosses
    /// midnight.
    var keepAwakeEndHour =
        UserDefaults.standard.object(forKey: HostModel.keepAwakeScheduleEndHourKey) as? Int
            ?? HostModel.keepAwakeDefaultEndHour

    /// Kept so the pane can tell a deliberate release from a pmset setting removed by hand, which is the state the recovery path exists for.
    var keepAwakeWithheld = false

    var keepAwakeScheduleTask: Task<Void, Never>?

    /// Its own flag because a release would be undone within a minute: the schedule re-applies on a clock. Sticks until a client connects or a switch is touched.
    var keepAwakeReleasedByHand = false

    /// pmset writes the wake into the machine schedule, which fires with nothing running; wake-on-LAN cannot help a phone arriving over the relay.
    var wakeScheduleHour: Int? =
        UserDefaults.standard.object(forKey: HostModel.wakeScheduleHourKey) as? Int

    var wakeScheduleBusy = false
    var wakeScheduleFailure: String?

    /// Read first because pmset allows one repeating pair and setting ours replaces whatever was there.
    var otherScheduledEvents: [String] = []

    var idleSleepMinutes: Int?

    var keepAwakePromptTask: Task<Void, Never>?

    /// Set rather than shown directly so the pane can raise it; a model must not put up a dialog from nowhere.
    var asksToReleaseKeepAwake = false

    /// The lid-close check is here, not in start(), because the Mac it matters on has its window closed after a crash.
    init() {
        Task { await adoptLidCloseSleepSetting() }
        startResourceSampling()
        // Started here so a Mac restarted inside its own window does not sit with the schedule off until the pane opens.
        updateKeepAwakeScheduleWatch()
    }

    /// Matched on ID: the name is the client's to choose and two devices can share one.
    func isConnected(_ id: String) -> Bool {
        connectedClients.contains { $0.id == id }
    }
    var log: [HostLogEntry] = []

    let permissions = Permissions()

    /// Own lock and @unchecked Sendable: commands arrive on the network queue and teardown on the main actor, and hopping either would put pointer events behind SwiftUI.
    let input = InputInjector()

    let displayPrivacy = DisplayPrivacyController()

    let privacyCurtain = DisplayPrivacyCurtain()

    var displayObserver: NSObjectProtocol?
    var privacyModeEnabled = false

    /// Cleared once applied, and left set on failure: a rejected switch means client and host disagree, and the window is where that is visible.
    var pendingCaptureSource: CaptureSource?

    /// pendingCaptureSource is the ask, not the answer; this is what is actually streamed.
    var capturingSource: CaptureSource?

    /// The last source that was counted, so a phone replaying its source on every reconnect is not counted as a change each time.
    @ObservationIgnored var lastCountedCaptureSource: CaptureSource?

    /// Kept so a source can be named rather than shown as a display ID or pid.
    var catalog: CaptureCatalog?

    var capturingSourceTitle: String? {
        guard let capturingSource, let catalog else { return nil }
        return catalog.all.first { $0.source == capturingSource }?.title
    }

    /// A counter: the rate subtraction is ResourceMeter's. nil means not hosting yet, distinct from a coordinator that sent zero.
    var streamedBytes: UInt64? {
        guard let stats = coordinator?.streamStatistics else { return nil }
        // Widened to UInt64 from the streamer Int count; video and audio are counted separately and summed.
        return UInt64(max(0, stats.bytesSent + stats.audioBytesSent))
    }

    /// On the model because a menu bar app runs with its window closed. Sampled from launch since a rate needs two readings.
    var resources = HostResourceSampler()

    /// Started once and never stopped: an app that is not hosting is still one somebody may ask about.
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

    var directPathOpen = false

    /// A pin carries no name and the name goes when the connection ends, so it is persisted for devices not attached.
    var clientNames: [String: String] =
        UserDefaults.standard.dictionary(forKey: HostModel.clientNamesKey) as? [String: String] ?? [:]

    static let clientNamesKey = "Peering.clientNames"

    func displayName(for clientID: String) -> String {
        clientNames[clientID] ?? clientID
    }

    /// nil when nothing is captured, not the last picture, which would claim the phone can see something it cannot.
    func snapshot(maxWidth: Int = 640) async -> CGImage? {
        await coordinator?.snapshot(maxWidth: maxWidth)
    }

    /// Nil until the first client opens a video connection: building one touches the catalogue, which needs Screen Recording. Written only from start() and stop().
    var coordinator: VideoCoordinator?

    var screenWatchTask: Task<Void, Never>?
    @ObservationIgnored let textFocusWatcher = TextFocusWatcher()
    @ObservationIgnored let pointerWatcher = PointerWatcher()

    /// Held so a problem is not announced twice: a denied grant fails on every stream attempt.
    var announcedCaptureProblem: String?

    var server: HostServer?
    var relayRegistration: RelayHostRegistration?

    /// Only half the answer: whether the relay then reached APNs is not visible from this Mac.
    var pushTestResult: String?

    @discardableResult
    func sendTestPush() -> String {
        // registeredPushTokens, not allPushTokens: the latter omits connected phones, which are told over the session rather than pushed.
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
    let terminalHooks = TerminalHookController()
    var pins: PinStore?
    var identity: SelfSignedIdentity?
    var spaceObserver: NSObjectProtocol?

    /// Bounded: an unbounded array in @Observable state re-renders forever.
    static let maxEvents = 60

    var port: UInt16 = HostModel.storedPort()

    /// pmset -a disablesleep 1 outlives the process, so quitting with it on would leave the Mac never sleeping. The restore runs only when this app set it (see sleepDisabledByThisAppKey).
    /// Synchronous: the process is going away, so there is no later to finish an await.
    func prepareForTermination() {
        virtualDisplayTeardownDepth += 1
        publishHostWidgetState(listening: false)
        // First: it is the one change a user would have to repair from outside this app, and relying on the window server collecting a virtual display at exit is an undocumented courtesy of a private API.
        virtualDisplayCreationGeneration &+= 1
        removeAllManagedVirtualDisplays()
        // Cancelled before the restore rather than after, so a check already in flight cannot land
        // on a model that is on its way out and put the switch back on.
        batteryWatchdog?.cancel()
        batteryWatchdog = nil
        restoreSleepDisabledIfOurs()
    }

    // MARK: - Capture

    var captureResolution: CaptureResolution = HostModel.storedCaptureResolution()
    var captureFrameRate: CaptureFrameRate = HostModel.storedCaptureFrameRate()
    var captureCodec: VideoCodec = HostModel.storedCaptureCodec()

    // MARK: - Virtual display

    /// Displays made at the phone's request; session-scoped, they go when the client that asked goes. See HostModel+VirtualDisplayManagement.swift.
    var managedVirtualDisplays: [VirtualDisplay] = []

    /// The management path derives a distinct product from this too: the window server accepted serial-only identities but reset their modes to 800 by 600. Never reuses a serial, to avoid racing the window server teardown.
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

    /// The wait inside VirtualDisplay turns the main run loop, so a second add/remove can arrive mid-operation; it is dropped so limit checks and fallback choices stay valid.
    var isMakingVirtualDisplay = false

    var logText: String { log.plainText }

    /// Bounded: a long-running host should not keep a year of history in UserDefaults.
    var sessions: [HostSessionRecord] =
        UserDefaults.standard.data(forKey: HostModel.sessionsKey)
            .flatMap { try? JSONDecoder().decode([HostSessionRecord].self, from: $0) }
            .map { Array($0.prefix(HostModel.maxSessions)) } ?? []

    var openSessions: [String: OpenSession] =
        UserDefaults.standard.data(forKey: HostModel.openSessionsKey)
            .flatMap { try? JSONDecoder().decode([String: OpenSession].self, from: $0) } ?? [:]

    /// Whether the store has been checked for what the last process abandoned. Once per process:
    /// after that, anything in ``openSessions`` is one of ours, running.
    var hasAdoptedAbandonedSessions = false

    // MARK: - Sleep prevention

    var batteryWatchdog: Task<Void, Never>?

    // MARK: - Device name

    /// The Computer Name from Sharing settings; the raw hostname is only a fallback.
    static var defaultDeviceName: String {
        if let localized = Host.current().localizedName, !localized.isEmpty {
            return localized
        }
        let host = ProcessInfo.processInfo.hostName
        let suffix = ".local"
        return host.hasSuffix(suffix) ? String(host.dropLast(suffix.count)) : host
    }
}
