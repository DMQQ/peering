import Foundation

public enum PreferenceKeys {
    public static let hidesPanelAfterSelect = "Peering.hidesPanelAfterSelect"
    public static let pipAutoStart = "Peering.pipAutoStart"
    public static let opensKeyboardForTextFields = "Peering.opensKeyboardForTextFields"
    /// Set by both finishing and skipping the tour.
    public static let hasSeenWelcome = "Peering.hasSeenWelcome"
    /// Set when the card appears, not when dismissed: the remote screen is rebuilt each session, so a flag written only by the tap would let it return.
    public static let hasSeenLandscapeHint = "Peering.hasSeenLandscapeHint"
    /// Whether a Mac may be reached through the relay, or only over the local network.
    /// Anonymous usage counts; on unless the user turns it off. See `Analytics`.
    public static let analyticsEnabled = "Peering.analyticsEnabled"
    public static let allowRelay = "Peering.allowRelay"
    public static let requireBiometricUnlock = "Peering.requireBiometricUnlock"
    /// Whether the Mac's audio is played on the phone, or dropped.
    public static let hostAudioMuted = "Peering.hostAudioMuted"
    public static let liveActivities = "Peering.liveActivities"
    public static let keyboardMode = "Peering.keyboardMode"
    /// Settings is unreachable while connected, so this is a preference and never a command; see ``SessionModel/applyInitialQuality()``.
    public static let streamQuality = "Peering.streamQuality"
    /// A flag rather than `sessionHistory.count == 1`: the history prunes to twenty records.
    public static let offeredAfterFirstSession = "Peering.offeredAfterFirstSession"
    /// The relay's day bucket (epoch seconds divided into days, see `Relay/src/quota.rs`), not a moment.
    public static let lowRelayOfferWindow = "Peering.lowRelayOfferWindow"
    /// Persisted so observe mode's no-input promise survives a relaunch.
    public static let interactionMode = "Peering.interactionMode"
    public static let scalesToFill = "Peering.scalesToFill"
    public static let pointerSpeed = "Peering.pointerSpeed"
    /// The terminal commands sent from this phone, newest first.
    public static let terminalHistory = "Peering.terminalHistory"
    public static let terminalTextSize = "Peering.terminalTextSize"
    public static let customMacros = "Peering.customMacros"

    // One flag per tour; read and written through ``Tour``.
    public static let hasSeenTourConnect = "Peering.hasSeenTourConnect"
    public static let hasSeenTourServers = "Peering.hasSeenTourServers"
    public static let hasSeenTourShell = "Peering.hasSeenTourShell"
    public static let hasSeenTourTerminal = "Peering.hasSeenTourTerminal"
    public static let hasSeenTourScreen = "Peering.hasSeenTourScreen"
}
