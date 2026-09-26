import Foundation

// The keys the app persists its own settings under.
//
// The types that read and write a setting live in this module, so its keys do too.

/// The keys the app persists its own settings under.
///
/// Named in one place so that the screen that obeys a setting and the panel that offers it cannot
/// spell the key differently: two spellings of one key is a switch that silently does nothing for
/// one of the two.
public enum PreferenceKeys {
    /// Whether picking something from a floating panel puts the panel away.
    public static let hidesPanelAfterSelect = "Peering.hidesPanelAfterSelect"
    /// Whether iOS floats the picture on its own when the app goes away.
    public static let pipAutoStart = "Peering.pipAutoStart"
    /// Whether the keyboard opens by itself when the Mac's focus lands in a text field.
    public static let opensKeyboardForTextFields = "Peering.opensKeyboardForTextFields"
    /// Whether the first-run introduction has been seen and dismissed.
    ///
    /// Set by both of its exits, finishing the tour and skipping it, because "I have seen it" and
    /// "I do not want to see it" are the same instruction here.
    public static let hasSeenWelcome = "Peering.hasSeenWelcome"
    /// Whether the turn-your-phone card has been shown, ever.
    ///
    /// Set the moment the card appears rather than when it is dismissed: it usually leaves by being
    /// turned away from or by its own timer. The remote screen is built fresh for each session, so a
    /// flag written only by the tap would come back for everybody else.
    public static let hasSeenLandscapeHint = "Peering.hasSeenLandscapeHint"
    /// Whether a Mac may be reached through the relay, or only over the local network.
    ///
    /// Read in two places that have to agree: ``SessionModel``, which decides whether to dial it,
    /// and ``SettingsPanel``/``FAQView``, which say so in words.
    public static let allowRelay = "Peering.allowRelay"
    /// Whether opening Peering requires the device owner's biometric authentication.
    public static let requireBiometricUnlock = "Peering.requireBiometricUnlock"
    /// Whether the Mac's own audio is played on the phone, or dropped silently. Persisted because it
    /// is a decision about the Mac being controlled rather than about one session.
    public static let hostAudioMuted = "Peering.hostAudioMuted"
    /// Whether Live Activities are shown during a session (Lock Screen and Dynamic Island).
    public static let liveActivities = "Peering.liveActivities"
    /// The input protocol selected for the on-screen keyboard.
    public static let keyboardMode = "Peering.keyboardMode"
    /// The bitrate preset a session runs at.
    ///
    /// The Settings tab is unreachable while connected (``ContentView`` swaps the whole tab bar for
    /// the remote screen), so it can write this preference and never a command; the session adopts
    /// it when it arrives, see ``SessionModel/applyInitialQuality()``.
    public static let streamQuality = "Peering.streamQuality"
    /// Whether the one-time offer that follows a user's first finished session has been made.
    ///
    /// A flag rather than `sessionHistory.count == 1`: the history keeps the last twenty records and
    /// prunes the rest, so its count answers "how much is stored".
    public static let offeredAfterFirstSession = "Peering.offeredAfterFirstSession"
    /// Which 24-hour window the "running low" offer was last made in, as the window's own number.
    ///
    /// The relay counts its allowance in epoch seconds divided into days (see `Relay/src/quota.rs`),
    /// and this stores that bucket rather than a moment.
    public static let lowRelayOfferWindow = "Peering.lowRelayOfferWindow"
    /// Whether the pointer drives the Mac or only watches it.
    ///
    /// Persisted because observe mode's no-input promise has to survive a relaunch: a mode that
    /// reset itself would hand the Mac back to whoever picked the phone up.
    public static let interactionMode = "Peering.interactionMode"
    /// Whether the picture is scaled up to reach the screen's edges.
    ///
    /// Persisted because it is a property of the source rather than of the moment: a window captured
    /// on its own is usually a different shape from the screen.
    public static let scalesToFill = "Peering.scalesToFill"
    /// What the joystick multiplies the pointer's travel by.
    ///
    /// A number rather than an index so the label and the arithmetic read the same, and persisted
    /// because it is a property of the hand rather than of the session.
    public static let pointerSpeed = "Peering.pointerSpeed"
    /// The terminal commands sent from this phone, newest first. In the defaults rather than in
    /// memory, because the remote screen it is shown on is built fresh for each session.
    public static let terminalHistory = "Peering.terminalHistory"
    /// The size the terminals draw their text at, in points. See ``TerminalTextSize``.
    public static let terminalTextSize = "Peering.terminalTextSize"
    /// The user's own macros, as encoded JSON.
    ///
    /// Written whenever the list changes and read once when the model is built, so the two ends of
    /// that round trip have to be spelling the same key.
    public static let customMacros = "Peering.customMacros"

    // The five first-run tours, one flag each.
    //
    // Five keys rather than one list of tours already seen, because a tour is owed by the screen it
    // belongs to and the screens are reached in an order the app does not decide: one list would
    // have to be kept in step with the screens themselves.
    //
    // Written by both exits of a tour, finishing it and skipping it, for the reason
    // ``hasSeenWelcome`` records. Read and written through ``Tour``.
    /// Whether the Connect screen's tips have been seen.
    public static let hasSeenTourConnect = "Peering.hasSeenTourConnect"
    /// Whether the Servers screen's tips have been seen.
    public static let hasSeenTourServers = "Peering.hasSeenTourServers"
    /// Whether the tips for a shell on a server have been seen.
    public static let hasSeenTourShell = "Peering.hasSeenTourShell"
    /// Whether the terminal's tips have been seen.
    public static let hasSeenTourTerminal = "Peering.hasSeenTourTerminal"
    /// Whether the remote screen's tips have been seen.
    public static let hasSeenTourScreen = "Peering.hasSeenTourScreen"
}
