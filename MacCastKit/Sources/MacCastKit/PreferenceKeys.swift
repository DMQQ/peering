import Foundation

// The keys the app persists its own settings under.
//
// Here rather than in the app because the types that read and write a setting live here: a
// key spelled twice, once where it is written and once where it is read, is a switch that
// silently does nothing for one of the two.

/// The keys the app persists its own settings under.
///
/// Named in one place when two views read one — the screen that obeys a setting and the panel that
/// offers it. Two spellings of the same key is a switch that silently does nothing for one of them,
/// which is the sort of bug that survives a lot of testing.
public enum PreferenceKeys {
    /// Whether picking something from a floating panel puts the panel away.
    public static let hidesPanelAfterSelect = "Peering.hidesPanelAfterSelect"
    /// Whether iOS floats the picture on its own when the app goes away.
    public static let pipAutoStart = "Peering.pipAutoStart"
    /// Whether the first-run introduction has been seen and dismissed.
    ///
    /// Set by both of its exits — finishing the tour and skipping it — because "I have seen it"
    /// and "I do not want to see it" are the same instruction here, and a flow that only
    /// remembered one of them would come back to someone who had already said no.
    public static let hasSeenWelcome = "Peering.hasSeenWelcome"
    /// Whether the turn-your-phone card has been shown, ever.
    ///
    /// Ever, rather than "in this session". The card is a nudge and not information: someone who
    /// reads it once and carries on working in portrait has answered it, and their answer is no.
    /// Asking again at the top of every session is not a reminder, it is charging them twice for
    /// the same question, and the remote screen is built fresh for each session, so anything not
    /// stored here comes back every single time.
    ///
    /// Set the moment the card appears rather than when it is dismissed. It leaves by being turned
    /// away from and by its own timer far more often than by a tap, and a flag written only by the
    /// tap would come back for everybody who used the card the way it was meant to be used.
    public static let hasSeenLandscapeHint = "Peering.hasSeenLandscapeHint"
    /// Whether a Mac may be reached through the relay, or only over the local network.
    ///
    /// Read in two places that have to agree — ``SessionModel``, which decides whether to dial
    /// it, and ``SettingsPanel``/``FAQView``, which say so in words. One spelling.
    public static let allowRelay = "Peering.allowRelay"
    /// Whether opening Peering requires the device owner's biometric authentication.
    public static let requireBiometricUnlock = "Peering.requireBiometricUnlock"
    /// Whether the Mac's own audio is played on the phone, or dropped silently.
    ///
    /// Persisted because it is a decision about the Mac being controlled rather than about this
    /// session: someone who does not want to hear what the Mac is playing does not want to hear
    /// it next time either.
    public static let hostAudioMuted = "Peering.hostAudioMuted"
    /// Whether Live Activities are shown during a session (Lock Screen and Dynamic Island).
    public static let liveActivities = "Peering.liveActivities"
    /// The input protocol selected for the on-screen keyboard.
    public static let keyboardMode = "Peering.keyboardMode"
    /// The bitrate preset a session runs at.
    ///
    /// Persisted because it is a decision about the picture rather than about one session — the
    /// same reasoning as ``hostAudioMuted``. It is also the only way the Settings tab can offer
    /// the setting at all: that tab is unreachable while connected (``ContentView`` swaps the
    /// whole tab bar for the remote screen), so it can write a preference and never a command.
    /// The session adopts this when it arrives — see ``SessionModel/applyInitialQuality()``.
    public static let streamQuality = "Peering.streamQuality"
    /// Whether the one-time offer that follows a user's first finished session has been made.
    ///
    /// A flag rather than `sessionHistory.count == 1`. The history keeps the last thirty records
    /// and prunes the rest, so its count answers "how much is stored"; this answers "what has
    /// already been said", which is the only question the offer has.
    public static let offeredAfterFirstSession = "Peering.offeredAfterFirstSession"
    /// Which 24-hour window the "running low" offer was last made in, as the window's own number.
    ///
    /// The relay counts its allowance in epoch seconds divided into days — see `Relay/src/quota.rs`
    /// — and this stores the bucket that came out rather than a moment. The only question ever
    /// asked of it is whether it is the bucket we are in now, and two spellings of one instant is
    /// how a comparison starts disagreeing with itself.
    public static let lowRelayOfferWindow = "Peering.lowRelayOfferWindow"
    /// Whether the pointer drives the Mac or only watches it.
    ///
    /// Persisted because observe mode's no-input promise has to survive a relaunch: a mode that
    /// reset itself would quietly hand the Mac back to whoever picked the phone up. Read by the
    /// screen that obeys the setting and by the panel that offers it.
    public static let interactionMode = "Peering.interactionMode"
    /// Whether the picture is scaled up to reach the screen's edges.
    ///
    /// Persisted because it is a property of the *source* rather than of the moment: a window
    /// captured on its own is usually a different shape from the screen, and someone who has just
    /// filled one will want the next one filled too.
    public static let scalesToFill = "Peering.scalesToFill"
    /// What the joystick multiplies the pointer's travel by.
    ///
    /// Kept as a number rather than an index so the label and the arithmetic read the same, and
    /// persisted because it is a property of the hand rather than of the session: someone who has
    /// found the speed they like wants it next time.
    public static let pointerSpeed = "Peering.pointerSpeed"
    /// The terminal commands sent from this phone, newest first.
    ///
    /// In the defaults rather than in memory, because the list is for finding a command again after
    /// the app has been away, and the remote screen it is shown on is built fresh for each session.
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
    // Five keys rather than one list of tours already seen, and that is the whole of the design.
    // A tour is owed by the *screen* it belongs to, and the screens are reached in an order the
    // app does not decide: somebody who never opens a shell on a server is owed the two tours
    // behind that screen forever, and somebody who does is owed them once. One list would make
    // "have I seen the tips for this screen" a question about a set that has to be kept in step
    // with the screens themselves, and the first new screen would be the one that was forgotten.
    //
    // Written by both exits of a tour (finishing it and skipping it) for the reason
    // ``hasSeenWelcome`` records: "I have read this" and "I do not want this" are the same
    // instruction, and a flag written only by the last step would come back for everybody who
    // pressed Skip on the first one.
    //
    // Read and written through ``Tour``, which is where the steps and the reset live; the keys are
    // here because a key spelled twice is a flag that silently does nothing for one of the two.
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
