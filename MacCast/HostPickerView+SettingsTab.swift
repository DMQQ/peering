import MacCastKit
import RemoteCore
import SSHCore
import SwiftUI
import UIKit

// MARK: - Settings Tab

struct SettingsTab: View {
    @Environment(SessionModel.self) private var model
    @AppStorage(PreferenceKeys.requireBiometricUnlock) private var requiresBiometricUnlock = false
    @AppStorage(PreferenceKeys.allowRelay) private var allowsRelay = true
    @AppStorage(PreferenceKeys.pipAutoStart) private var pipAutoStart = true
    @AppStorage(PreferenceKeys.liveActivities) private var liveActivitiesEnabled = true
    @AppStorage(PreferenceKeys.hasSeenWelcome) private var hasSeenWelcome = true
    @AppStorage(PreferenceKeys.hidesPanelAfterSelect) private var hidesPanelAfterSelect = true
    @AppStorage(PreferenceKeys.interactionMode) private var interactionMode: InteractionMode = .control
    @AppStorage(PreferenceKeys.scalesToFill) private var scalesToFill = false
    @AppStorage(PreferenceKeys.streamQuality) private var streamQuality: SessionModel.StreamQuality = .auto
    @State private var deviceNameDraft = ""
    /// Whether the copy has just happened, so the row can say so and then stop saying so.
    @State private var copiedDiagnostics = false
    @FocusState private var deviceNameFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        TabScreenHeader(
                            "Settings",
                            detail: "Defaults for this device and every session."
                        )
                        deviceSection
                        controlsSection
                        qualitySection
                        remoteAccessSection
                        securitySection
                        pipSection
                        homeScreenWidgetSection
                        liveActivitySection
                        notificationsSection
                        if !model.pairedHostIDs.isEmpty { trustedMacsSection }
                        identitySection
#if DEBUG
                        developerSection
#endif
                        moreSection
                        legalSection
                    }
                    .adaptiveContentColumn()
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                    .padding(.bottom, 36)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                if !deviceNameFocused {
                    deviceNameDraft = model.device.name
                }
            }
            // The permission can have been changed in iOS Settings since this screen was last
            // looked at, and the row below reports on it rather than offering a switch of its own.
            .task { await model.refreshNotificationAuthorization() }
            .onChange(of: deviceNameFocused) { _, focused in
                if !focused { commitDeviceName() }
            }
        }
    }

    private var deviceSection: some View {
        Controls.card(
            "This device",
            footer: "The name shown to Macs when you connect. Tap the name to edit it."
        ) {
            Controls.row("Device name", systemImage: AdaptiveLayout.deviceSymbol) {
                TextField("Name shown to Macs", text: $deviceNameDraft)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .focused($deviceNameFocused)
                    .onSubmit {
                        commitDeviceName()
                        deviceNameFocused = false
                    }
            }
        }
    }

    private var controlsSection: some View {
        Controls.card("Session controls", footer: model.keyboardMode.explanation) {
            Controls.picker("Interaction", systemImage: "hand.point.up.left", selection: $interactionMode) {
                ForEach(InteractionMode.allCases) { mode in
                    Text(mode == .control ? "Control" : "Observe").tag(mode)
                }
            }

            Controls.divider

            // The two answers are kept to two words each, and that is a layout constraint rather
            // than a copy decision. A menu picker prints its value on the trailing edge of the row
            // and wraps rather than truncating, so "Fit whole screen" took two lines and pushed
            // the row's own chevron out to the side of them — in a column where every other row is
            // one line. The row's label carries the subject ("Picture"); the answers only have to
            // carry the difference between them.
            Controls.picker(
                "Picture",
                systemImage: "arrow.up.left.and.arrow.down.right",
                selection: $scalesToFill
            ) {
                Text("Fit screen").tag(false)
                Text("Fill screen").tag(true)
            }

            Controls.divider

            Controls.picker("Keyboard", systemImage: "keyboard", selection: Binding(
                get: { model.keyboardMode },
                set: { model.setKeyboardMode($0) }
            )) {
                ForEach(KeyboardMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }

            Controls.divider

            Controls.toggle(
                "Close panels after selecting",
                systemImage: "rectangle.on.rectangle",
                isOn: $hidesPanelAfterSelect
            )
        }
    }

    /// The bitrate preset, as the one setting the next session starts from.
    ///
    /// It is here because it could not be found anywhere else. The control has existed for a
    /// while, but only inside a running session — the gear panel and the speed chip on the remote
    /// screen — and this tab is unreachable while one is running, so the two never meet and the
    /// setting read as one that did not exist.
    ///
    /// Which is also why this row writes a preference and tells nobody. Every other quality
    /// control in the app sends a figure to the Mac over a live connection; here there is no
    /// connection to send it over by construction. ``SessionModel`` reads this back when a
    /// session arrives and hands it over then.
    ///
    /// A `Menu` rather than ``Controls/picker(_:systemImage:selection:options:)``, which is what
    /// the rest of this card uses. Two reasons, and the first is the one recorded on the
    /// "Picture" row above: a menu picker prints the selected option on the trailing edge and
    /// wraps rather than truncating it, and the options here carry their bitrate — "Auto,
    /// follows the network" is not a value that fits on the end of a row. The second is that the
    /// options are worth reading in full, and a `Menu` separates the two jobs: the row shows the
    /// short name, the popup shows ``StreamQuality/menuTitle`` with its figure. It is the same
    /// arrangement, and the same words, as the speed chip on the remote screen.
    private var qualitySection: some View {
        Controls.card(
            "Stream quality",
            footer: "The level a session starts at. Changing it during a session changes this too, so the next one starts where you left off."
        ) {
            Controls.row("Quality", systemImage: "speedometer") {
                Menu {
                    ForEach(SessionModel.StreamQuality.allCases, id: \.self) { preset in
                        Button {
                            streamQuality = preset
                        } label: {
                            if preset == streamQuality {
                                Label(preset.menuTitle, systemImage: "checkmark")
                            } else {
                                Text(preset.menuTitle)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(streamQuality.title)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .tint(.white.opacity(0.72))
                .font(.subheadline)
                .accessibilityLabel("Stream quality")
                .accessibilityValue(streamQuality.title)
            }
        }
    }

    private var remoteAccessSection: some View {
        Controls.card(
            "Remote access",
            footer: "Relay connects across networks. Privacy mode dims the Mac's displays without stopping the stream."
        ) {
            Controls.toggle("Allow relay connections", systemImage: "network", isOn: $allowsRelay)
            Controls.divider
            Controls.toggle("Privacy mode", systemImage: "moon.fill", isOn: Binding(
                get: { model.privacyModeEnabled },
                set: { model.setPrivacyMode($0) }
            ))

            // The subscription had no door until now — the paywall could only be reached by the
            // relay refusing a connection for quota, which means the only people who could buy it
            // were the ones who had already been turned away. This is the door for everybody else,
            // and it sits under Remote access because the relay is what it buys.
            //
            // Hidden only once the plan is unlimited, which is the point at which there is nothing
            // left to sell. It used to hide for anybody who had bought anything, which was the same
            // thing when there was one paid tier; now it would take the ladder away from the
            // subscriber on the metered one, who has the most reason to climb it.
            if !model.storeManager.relayPlan.isUnlimited {
                Controls.divider
                Button { model.paywallReason = .upgrade } label: {
                    Controls.row("Upgrade to Pro", systemImage: "sparkles") {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(RailButtonStyle(scale: 0.99))
            }
        }
    }

    private var securitySection: some View {
        Controls.card("Security") {
            Controls.toggle("Require \(DeviceAuthentication.biometryName) on open", systemImage: DeviceAuthentication.biometrySymbol, isOn: Binding(
                get: { requiresBiometricUnlock },
                set: { requested in
                    guard requested else {
                        requiresBiometricUnlock = false
                        return
                    }
                    Task {
                        if await DeviceAuthentication.authenticate(
                            reason: "Protect access to your paired Macs."
                        ) {
                            requiresBiometricUnlock = true
                        }
                    }
                }
            ))
            .disabled(!DeviceAuthentication.isAvailable)
        }
    }

    /// The floating window, in the Settings tab.
    ///
    /// The same two controls as the session panel's, and the same plan behind them. On a plan that
    /// does not include it, the switch is still the switch, dimmed and inert, with the plan's name
    /// on its top-trailing corner rather than beside it: an overlay costs the row no width, and a
    /// badge that takes width is a badge that moves every other control in the row when the plan
    /// changes. The rows that only make sense once the feature works (the manual start and the
    /// diagnostic it produces) are the ones that are not drawn. The footer carries the sentence
    /// about which plan adds it.
    private var pipSection: some View {
        Controls.card(
            "Picture in Picture",
            footer: model.storeManager.access.includes(.pictureInPicture)
                ? "Peering can keep a live view of your Mac floating over other apps."
                : "It is part of \(PlanCapability.pictureInPicture.minimumPlan.name), with sound from the Mac and files that move both ways."
        ) {
            PlanLocked(capability: .pictureInPicture, title: "Float automatically") {
                Controls.toggle("Float automatically", systemImage: "pip", isOn: $pipAutoStart)
                    .onChange(of: pipAutoStart) { _, on in model.setPiPAutoStart(on) }
            }

            if model.storeManager.access.includes(.pictureInPicture) {
                Controls.divider

                Controls.row("Try it now", systemImage: "pip.enter") {
                    Button("Start") { model.startPiP() }
                        .font(.subheadline.weight(.medium))
                        .disabled(!model.isPiPSupported || !model.phase.holdsSession)
                }

                if let attempt = model.pipLastAttempt {
                    Controls.divider
                    Controls.row("Last attempt", systemImage: "clock.arrow.circlepath") {
                        Text(attempt)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let refusal = model.pipLastRefusal {
                        Text(refusal)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var homeScreenWidgetSection: some View {
        Controls.card(
            "Home Screen widget",
            footer: "Add Peering from the widget gallery for one-tap access to your last Mac."
        ) {
            HomeScreenWidgetPreview(
                hostNames: model.pairedHostIDs.prefix(3).map {
                    model.displayName(forHostID: $0) ?? "A Mac"
                }
            )
            .padding(.vertical, 5)
        }
    }

    private var liveActivitySection: some View {
        Controls.card(
            "Live Activity",
            footer: "Shows session status and duration on the Lock Screen and in Dynamic Island."
        ) {
            Controls.toggle("Show live activity", systemImage: "lock.fill", isOn: $liveActivitiesEnabled)
                .onChange(of: liveActivitiesEnabled) { _, enabled in
                    SessionActivity.shared.preferenceChanged(enabled: enabled)
                }

            Controls.divider

            // Lock Screen widget preview
            VStack(alignment: .leading, spacing: 10) {
                Text("Lock Screen preview")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                LockScreenWidgetPreview()
                    .opacity(liveActivitiesEnabled ? 1 : 0.45)
            }
            .padding(.vertical, 4)
        }
    }

    /// Being told that a terminal is waiting, in the Settings tab.
    ///
    /// **The one gated row in this file that is not a control.** There is nothing here to switch:
    /// the banner is raised because a shell stopped, and the only thing the user decides is the
    /// permission iOS asked for the first time they reached for a Mac. So the row is drawn as
    /// itself, says what a plan without it would be missing, and on that plan the tap opens the
    /// paywall through ``PlanLocked``, which is the whole of what this screen can honestly offer.
    ///
    /// **The state it prints is the system permission, not a preference of ours.** A row that
    /// said "On" beside a permission the user refused would be the app claiming something it
    /// cannot do, and the place to change it is iOS Settings, which the footer names.
    private var notificationsSection: some View {
        let included = model.storeManager.access.includes(.terminalAlerts)

        return Controls.card(
            "Notifications",
            footer: included
                ? "A shell that stops for an answer puts a banner up while Peering is not in front of you, on this device and through the Mac when no session is open. iOS carries the permission under Settings, Notifications, Peering."
                : "Being told when a terminal needs you is part of \(PlanCapability.terminalAlerts.minimumPlan.name), with sound from the Mac, Picture in Picture and files that move both ways."
        ) {
            PlanLocked(capability: .terminalAlerts, title: "Told when a shell needs you") {
                Controls.row("Terminal needs you", systemImage: "bell.badge") {
                    Text(model.notificationsAuthorized ? "On" : "Off")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var trustedMacsSection: some View {
        Controls.card("Trusted Macs") {
            ForEach(Array(model.pairedHostIDs.enumerated()), id: \.element) { index, hostID in
                Controls.row(model.displayName(forHostID: hostID) ?? hostID, systemImage: "macbook") {
                    Button("Forget", role: .destructive) { model.forget(hostID: hostID) }
                        .font(.subheadline)
                        .foregroundStyle(ColorPalette.danger)
                }
                if index < model.pairedHostIDs.count - 1 { Controls.divider }
            }
        }
    }

    /// What this device *is*, rather than the one thing that could be done to it.
    ///
    /// This card used to end in a reset button, and it is gone on purpose rather than by accident:
    /// the relay counts free minutes against the client ID, so minting a fresh identity handed
    /// whoever found the button a fresh free allowance. Do not put it back. What is left is the
    /// half that was always worth reading — which ID the Macs know this phone by, where the key
    /// lives, and how many Macs have paired with it.
#if DEBUG
    /// A developer's way to see the app on a plan they have not bought.
    ///
    /// **Behind `#if DEBUG` and second from the bottom**, which are two rules doing the same job:
    /// it is not something a user should find by scrolling, and it is not in any build one ever
    /// receives. `Tools/install-iphone.sh` builds Debug, so this is on a phone installed from this
    /// repository and never in an App Store build.
    ///
    /// **It changes the app and not the wire.** Every gate, padlock and plan card reads
    /// ``StoreManager/access``, which is what this overrides; what a session *states* to the relay
    /// is ``StoreManager/relayPlan``, read from the real entitlement either way. So the gated
    /// surfaces can be looked at on any plan, and a session is still metered as whatever the
    /// account actually pays for — which is the half of this that would otherwise be a way to
    /// spend relay allowance, and is not the half being tested.
    private var developerSection: some View {
        Controls.card(
            "Developer",
            footer: """
                Changes what this app shows, not what the relay is told: sessions stay metered at \
                whatever this Apple Account pays for.
                """
        ) {
            Controls.row("Plan override", systemImage: "hammer") {
                Menu {
                    Button("Off") { model.storeManager.setPlanOverride(nil) }
                    ForEach(RelayPlan.allCases, id: \.self) { plan in
                        Button {
                            model.storeManager.setPlanOverride(plan)
                        } label: {
                            if model.storeManager.planOverride == plan {
                                Label(plan.name, systemImage: "checkmark")
                            } else {
                                Text(plan.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(model.storeManager.planOverride?.name ?? "Real")
                            .foregroundStyle(model.storeManager.planOverride == nil ? .secondary : .primary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .tint(.white.opacity(0.72))
                .font(.subheadline)
                .accessibilityLabel("Plan override")
                .accessibilityValue(model.storeManager.planOverride?.name ?? "Real")
            }
        }
    }
#endif

    private var identitySection: some View {
        Controls.card(
            "Device identity",
            footer: "How Macs recognise this device. Created once, on first launch."
        ) {
            Controls.row("Device ID", systemImage: "number") {
                Text(model.device.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Controls.divider

            Controls.row("Private key", systemImage: "key.fill") {
                Text("P-256 · in Keychain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Controls.divider

            Controls.row("Paired Macs", systemImage: "macbook") {
                Text("\(model.pairedHostIDs.count)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var moreSection: some View {
        Controls.card("More") {
            // First, because it is the only row in this card that is about something other than
            // the app you are holding, and the one a second Mac needs: the Mac app is a download
            // rather than an App Store install, so somebody setting up another machine has to come
            // back here for it.
            Link(destination: PeeringSite.download) {
                Controls.row("Peering for Mac", systemImage: "arrow.down.circle") {
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(RailButtonStyle(scale: 0.99))
            .foregroundStyle(ColorPalette.ink)

            Controls.divider

            Button {
                hasSeenWelcome = false
            } label: {
                Controls.row("Show introduction again", systemImage: "rectangle.stack") {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(RailButtonStyle(scale: 0.99))

            Controls.divider

            // **All five, and no way to pick one.** A tip is skipped for one of two reasons: the
            // person has read what it says, or they were in the middle of something and wanted it
            // gone. Nothing on this screen can tell those apart, and the second is the one that
            // comes back here looking for what it dismissed. So the row puts every tour back and
            // the screens that owe one show it the next time they are reached — which is also why
            // this row has no list of the five under it: a list would be a decision to make about
            // which tip was skipped, and the person who skipped it does not remember.
            Button {
                Tour.resetAll()
            } label: {
                Controls.row("Show tips again", systemImage: "lightbulb") {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(RailButtonStyle(scale: 0.99))

            Controls.divider

            // The only way anyone can tell us something is wrong.
            //
            // There is no analytics and no crash reporting in this app — that is a promise on the
            // privacy page, not an oversight — so a report and an App Store review are the whole
            // of the feedback. Which makes this row's job worth doing properly: it opens the
            // user's own mail client, where they can see exactly what is being sent before they
            // send it, rather than a form that posts somewhere.
            Link(destination: Self.reportURL) {
                Controls.row("Report an issue", systemImage: "envelope") {
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(RailButtonStyle(scale: 0.99))
            .foregroundStyle(ColorPalette.ink)

            Controls.divider

            // Beside the mail link rather than inside it, because a diagnostics blob pasted into
            // a draft looks like an attachment and reads like one: this way the user can put it
            // where it is asked for, or nowhere.
            Button {
                UIPasteboard.general.string = Diagnostics.text(model: model)
                copiedDiagnostics = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copiedDiagnostics = false
                }
            } label: {
                Controls.row(
                    "Copy diagnostics",
                    systemImage: copiedDiagnostics ? "checkmark" : "doc.on.doc"
                ) {
                    Text(copiedDiagnostics ? "Copied" : "")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(copiedDiagnostics ? ColorPalette.accent : Color.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(RailButtonStyle(scale: 0.99))
            .foregroundStyle(ColorPalette.ink)
        }
    }

    /// The two documents that have to be reachable from inside the app.
    ///
    /// **A card of its own at the very bottom, and that is the whole of where it goes.** The card
    /// above is about this app and this Mac: the download, the introduction, the way to tell us
    /// something is wrong. An agreement is not that, and nobody setting up a second machine is
    /// looking for it, so it sits below everything a person came here to do and above nothing.
    ///
    /// Both open in the browser rather than in a web view. A page drawn inside the app would be a
    /// second copy of a document that has to say the same thing as the one the App Store listing
    /// points at, and two copies of a privacy policy is one copy too many.
    private var legalSection: some View {
        Controls.card("Legal") {
            externalLink("Privacy policy", systemImage: "hand.raised", to: PeeringSite.privacy)

            Controls.divider

            externalLink("Terms of use", systemImage: "doc.text", to: PeeringSite.terms)
        }
    }

    /// One row that leaves the app.
    ///
    /// The trailing arrow is the same one the download row above uses, and it is doing the same
    /// job: this is the glyph that says a tap goes somewhere else rather than opening a screen
    /// inside the app, which for a legal page is the difference between reading it and wondering
    /// where the back button went.
    private func externalLink(_ title: String, systemImage: String, to url: URL) -> some View {
        Link(destination: url) {
            Controls.row(title, systemImage: systemImage) {
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RailButtonStyle(scale: 0.99))
        .foregroundStyle(ColorPalette.ink)
    }

    /// Where a report goes, with the two facts that make one actionable already written in it.
    ///
    /// The app version and the iOS release are the first things anyone has to ask for, and asking
    /// costs a round trip with somebody who is already annoyed enough to be writing in. Both are
    /// written into the draft where the sender can read and delete them.
    ///
    /// Nothing else is, deliberately. Not the device ID, not the name of the Mac, not the
    /// last session — a bug report should not be the one place this app hands over information
    /// about the user, and none of it is needed to answer "it went black when I rotated".
    private static var reportURL: URL {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"

        // The blank headings are the report's shape, offered rather than imposed: a one-line
        // "it doesn't work" under a subject of the same is what arrives otherwise, and neither
        // end of that exchange enjoys it.
        let body = """
            What happened:


            What I expected:


            Peering \(version) (\(build))
            \(ProcessInfo.processInfo.operatingSystemVersionString)
            """

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "support@getpeering.app"
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Peering issue"),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url ?? URL(string: "mailto:support@getpeering.app")!
    }


    private func commitDeviceName() {
        let trimmed = deviceNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            deviceNameDraft = model.device.name
            return
        }
        model.setDeviceName(trimmed)
        deviceNameDraft = model.device.name
    }
}

// MARK: - Home Screen Widget Preview

/// The two home-screen sizes, side by side and to scale.
///
/// Side by side rather than stacked, which is how the gallery shows them and how they are
/// actually met: the pair is the choice being offered, and one above the other reads as two
/// things to scroll past. The proportions are the real ones — a medium widget is a little over
/// twice the width of a small and exactly the same height — and every size in here is derived
/// from the width the card has, so the pair fills a large phone and still fits a small one
/// instead of being one fixed size that is wrong on most of them.
private struct HomeScreenWidgetPreview: View {
    let hostNames: [String]

    /// A medium widget is 338×158 points and a small is 158×158, so this ratio is the whole of
    /// what makes one look like the other. The gap between them is not from the gallery — two
    /// widgets on a home screen sit flush — it is what separates two diagrams on one card.
    private static let mediumToSmall: CGFloat = 2.14
    private static let gap: CGFloat = 12

    /// The size of the small preview, and the unit everything else is drawn in: `design` is how
    /// the numbers below were chosen, and the small's side scales all of them.
    ///
    /// Seeded rather than measured on the first pass, because a `@State` starts at whatever it is
    /// declared with and the pair would otherwise be drawn once at the wrong size. `design` is
    /// the width the pair was drawn at by hand; anything that fits inside the narrowest phone is
    /// close enough for the frame before the measurement arrives.
    @State private var smallSide: CGFloat = 94
    private static let design: CGFloat = 132

    private var primaryName: String { hostNames.first ?? "Your Mac" }

    /// Everything inside a preview, as a multiple of the size it is being drawn at. One unit at
    /// the design size is one point, so the numbers stay the ones a designer would have picked.
    private var unit: CGFloat { smallSide / Self.design }

    var body: some View {
        HStack(alignment: .top, spacing: Self.gap) {
            column("Small") { small }
            column("Medium") { medium }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Measured rather than assumed: the card is 18 points in from the screen's edge and 16
        // more in from its own, and what is left of an iPhone's width differs by 70 points across
        // the sizes this runs on. Reading it here rather than at the call site keeps the preview
        // and the card that has to hold it from having to agree on a number.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            guard width > 0 else { return }
            smallSide = (width - Self.gap) / (1 + Self.mediumToSmall)
        }
    }

    private func column<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var small: some View {
        VStack(spacing: 7 * unit) {
            Image(systemName: "display")
                .font(.system(size: 27 * unit, weight: .medium))
            Text(primaryName)
                .font(.system(size: 17 * unit, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text("Tap to connect")
                .font(.system(size: 11 * unit))
                .foregroundStyle(.secondary)
        }
        .frame(width: smallSide, height: smallSide)
        .widgetPreviewSurface(radius: 24 * unit)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 8 * unit) {
            HStack(spacing: 5 * unit) {
                Image(systemName: "display")
                    .font(.system(size: 10 * unit, weight: .medium))
                Text("PEERING")
                    .font(.system(size: 10 * unit, weight: .semibold, design: .rounded))
                    .tracking(1 * unit)
                Spacer()
            }
            .foregroundStyle(.secondary)

            ForEach(Array(displayedNames.enumerated()), id: \.offset) { _, name in
                HStack(spacing: 8 * unit) {
                    Image(systemName: "macbook")
                        .font(.system(size: 13 * unit, weight: .medium))
                    Text(name)
                        .font(.system(size: 13 * unit, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10 * unit, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(15 * unit)
        // The same height as the small, which is what makes the pair read as one set of choices.
        // It used to be a `minHeight` on a flexible width, so the medium grew with the card and
        // its proportion drifted on every phone.
        .frame(
            width: smallSide * Self.mediumToSmall,
            height: smallSide,
            alignment: .topLeading
        )
        .widgetPreviewSurface(radius: 24 * unit)
    }

    private var displayedNames: [String] {
        hostNames.isEmpty ? ["Pair a Mac to connect"] : hostNames
    }
}

private extension View {
    /// The surface of a widget: a lit pane rather than a card of the app's own.
    ///
    /// The radius is passed in rather than fixed at 24 because the previews are no longer one
    /// size. A real widget's corner is about a sixth of its height, and a preview drawn at 94
    /// points with a 24-point radius would be rounder than any widget on the home screen.
    func widgetPreviewSurface(radius: CGFloat) -> some View {
        background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.13), .white.opacity(0.07)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(.white.opacity(0.12))
                }
        }
    }
}

// MARK: - Lock Screen Widget Preview

private struct LockScreenWidgetPreview: View {
    var body: some View {
        HStack(spacing: 10) {
            // Compact leading — app icon placeholder
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: "cursorarrow.motionlines")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Peering")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                HStack(spacing: 6) {
                    Image(systemName: "wifi")
                        .font(.system(size: 9, weight: .semibold))
                    Text("LAN · 0:24")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.white.opacity(0.7))
            }

            Spacer()

            // Timer pill
            Text("0:24")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.15), in: Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(white: 0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                }
        )
        .padding(.top, 2)
    }
}
