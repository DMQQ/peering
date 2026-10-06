import MacCastKit
import MessageUI
import RemoteCore
import SSHCore
import SwiftUI
import UIKit

// MARK: - Settings Tab

struct SettingsTab: View {
    @Environment(SessionModel.self) private var model
    @AppStorage(PreferenceKeys.requireBiometricUnlock) private var requiresBiometricUnlock = false
    @AppStorage(PreferenceKeys.allowRelay) private var allowsRelay = true
    @AppStorage(PreferenceKeys.analyticsEnabled) private var analyticsEnabled = true
    @AppStorage(PreferenceKeys.pipAutoStart) private var pipAutoStart = true
    @AppStorage(PreferenceKeys.liveActivities) private var liveActivitiesEnabled = true
    @AppStorage(PreferenceKeys.hasSeenWelcome) private var hasSeenWelcome = true
    @AppStorage(PreferenceKeys.hidesPanelAfterSelect) private var hidesPanelAfterSelect = true
    @AppStorage(PreferenceKeys.opensKeyboardForTextFields) private var opensKeyboardForTextFields = true
    @AppStorage(PreferenceKeys.interactionMode) private var interactionMode: InteractionMode = .control
    @AppStorage(PreferenceKeys.scalesToFill) private var scalesToFill = false
    @AppStorage(PreferenceKeys.streamQuality) private var streamQuality: SessionModel.StreamQuality = .auto
    @State private var deviceNameDraft = ""
    @State private var query = ""
    @State private var copiedDiagnostics = false
    @State private var showingMailComposer = false
    @FocusState private var deviceNameFocused: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        TabScreenHeader(
                            String(localized: "Settings"),
                            detail: String(localized: "Defaults for this device and every session.")
                        )
                        SettingsSearchField(query: $query)
                        if shows(.device) { deviceSection }
                        if shows(.controls) { controlsSection }
                        if shows(.quality) { qualitySection }
                        if shows(.remoteAccess) { remoteAccessSection }
                        if shows(.security) { securitySection }
                        if shows(.pip) { pipSection }
                        if shows(.widget) { homeScreenWidgetSection }
                        if shows(.liveActivity) { liveActivitySection }
                        if shows(.notifications) { notificationsSection }
                        if !model.pairedHostIDs.isEmpty, shows(.trustedMacs) { trustedMacsSection }
                        if shows(.identity) { identitySection }
#if DEBUG
                        if shows(.developer) { developerSection }
#endif
                        if shows(.more) { moreSection }
                        if shows(.legal) { legalSection }
                        if SettingsSearch.hasNoMatch(query) {
                            SettingsSearch.noResults(query)
                        }
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
            // The permission can change in iOS Settings, so the row reports it rather than offering a switch.
            .task { await model.refreshNotificationAuthorization() }
            .onChange(of: deviceNameFocused) { _, focused in
                if !focused { commitDeviceName() }
            }
        }
    }

    private func shows(_ section: SettingsSearch.Section) -> Bool {
        SettingsSearch.matches(section, query)
    }

    private var deviceSection: some View {
        Controls.card(
            String(localized: "This device"),
            footer: String(localized: "The name shown to Macs when you connect. Tap the name to edit it.")
        ) {
            Controls.row(String(localized: "Device name"), systemImage: AdaptiveLayout.deviceSymbol) {
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
        Controls.card(String(localized: "Session controls"), footer: model.keyboardMode.explanation) {
            Controls.picker(String(localized: "Interaction"), systemImage: "hand.point.up.left", selection: $interactionMode) {
                ForEach(InteractionMode.allCases) { mode in
                    Text(mode == .control ? "Control" : "Observe").tag(mode)
                }
            }

            Controls.divider

            // Answers are two words each, a layout constraint: a menu picker wraps rather than truncating, and "Fit whole screen" took two lines and pushed the chevron aside.
            Controls.picker(
                String(localized: "Picture"),
                systemImage: "arrow.up.left.and.arrow.down.right",
                selection: $scalesToFill
            ) {
                Text("Fit screen").tag(false)
                Text("Fill screen").tag(true)
            }

            Controls.divider

            Controls.picker(String(localized: "Keyboard"), systemImage: "keyboard", selection: Binding(
                get: { model.keyboardMode },
                set: { model.setKeyboardMode($0) }
            )) {
                ForEach(KeyboardMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }

            Controls.divider

            Controls.toggle(
                String(localized: "Open keyboard for text fields"),
                systemImage: "keyboard.badge.ellipsis",
                isOn: $opensKeyboardForTextFields
            )

            Controls.divider

            Controls.toggle(
                String(localized: "Close panels after selecting"),
                systemImage: "rectangle.on.rectangle",
                isOn: $hidesPanelAfterSelect
            )
        }
    }

    /// Here because the control otherwise exists only inside a running session, which this tab cannot be open during. It writes a preference and tells nobody: there is no connection to send it over, and ``SessionModel`` reads it back when a session arrives.
    /// A `Menu` rather than ``Controls/picker(_:systemImage:selection:options:)``: a picker prints the option on the trailing edge and wraps, and these options carry their bitrate. The row shows the short name and the popup ``StreamQuality/menuTitle``, as the speed chip does.
    private var qualitySection: some View {
        Controls.card(String(localized: "Stream quality"),
            footer: String(localized: "The level a session starts at. Changing it during a session changes this too, so the next one starts where you left off.")
        ) {
            Controls.row(String(localized: "Quality"), systemImage: "speedometer") {
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
            String(localized: "Remote access"),
            footer: model.phase == .ready
                ? String(localized: "Relay connects across networks. Privacy mode dims the Mac's displays without stopping the stream.")
                : String(localized: "Relay connects across networks.")
        ) {
            Controls.toggle(String(localized: "Allow relay connections"), systemImage: "network", isOn: $allowsRelay)
            // Per session: the Mac is only told while one is live, and it is undone on disconnect.
            if model.phase == .ready {
                Controls.divider
                Controls.toggle(String(localized: "Privacy mode"), systemImage: "moon.fill", isOn: Binding(
                    get: { model.privacyModeEnabled },
                    set: { model.setPrivacyMode($0) }
                ))
            }

            // The subscription's door for everybody else: the paywall was otherwise reachable only by the relay refusing for quota. Hidden only once the plan is unlimited, not for anyone who has bought something, so a metered subscriber can still climb the ladder.
            if !model.storeManager.relayPlan.isUnlimited {
                Controls.divider
                Button { model.paywallReason = .upgrade } label: {
                    Controls.row(String(localized: "Upgrade to Pro"), systemImage: "sparkles") {
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
        Controls.card(
            String(localized: "Security and privacy"),
            footer: String(localized: "Usage statistics are anonymous counts of app opens and sessions, with the app version and your plan. Never your screen, files, keystrokes or Macs.")
        ) {
            Controls.toggle(String(localized: "Require \(DeviceAuthentication.biometryName) on open"), systemImage: DeviceAuthentication.biometrySymbol, isOn: Binding(
                get: { requiresBiometricUnlock },
                set: { requested in
                    guard requested else {
                        requiresBiometricUnlock = false
                        return
                    }
                    Task {
                        if await DeviceAuthentication.authenticate(
                            reason: String(localized: "Protect access to your paired Macs.")
                        ) {
                            requiresBiometricUnlock = true
                        }
                    }
                }
            ))
            .disabled(!DeviceAuthentication.isAvailable)
            Controls.divider
            Controls.toggle(String(localized: "Share anonymous usage statistics"), systemImage: "chart.bar", isOn: $analyticsEnabled)
                .onChange(of: analyticsEnabled) { _, enabled in PostHogConfiguration.setEnabled(enabled) }
        }
    }

    /// On a plan without it the switch is dimmed and inert with the plan's name overlaid at the corner: an overlay costs no width, so the row does not move when the plan changes.
    private var pipSection: some View {
        Controls.card(
            String(localized: "Picture in Picture"),
            footer: model.storeManager.access.includes(.pictureInPicture)
                ? String(localized: "Peering can keep a live view of your Mac floating over other apps.")
                : String(localized: "It is part of \(PlanCapability.pictureInPicture.minimumPlan.name), with sound from the Mac and files that move both ways.")
        ) {
            PlanLocked(capability: .pictureInPicture, title: "Float automatically") {
                Controls.toggle(String(localized: "Float automatically"), systemImage: "pip", isOn: $pipAutoStart)
                    .onChange(of: pipAutoStart) { _, on in model.setPiPAutoStart(on) }
            }
        }
    }

    private var homeScreenWidgetSection: some View {
        Controls.card(
            String(localized: "Home Screen widget"),
            footer: String(localized: "Add Peering from the widget gallery for one-tap access to your last Mac.")
        ) {
            HomeScreenWidgetPreview(
                hostNames: model.pairedHostIDs.prefix(3).map {
                    model.displayName(forHostID: $0) ?? String(localized: "A Mac")
                }
            )
            .padding(.vertical, 5)
        }
    }

    private var liveActivitySection: some View {
        Controls.card(
            String(localized: "Live Activity"),
            footer: String(localized: "Shows session status and duration on the Lock Screen and in Dynamic Island.")
        ) {
            Controls.toggle(String(localized: "Show live activity"), systemImage: "lock.fill", isOn: $liveActivitiesEnabled)
                .onChange(of: liveActivitiesEnabled) { _, enabled in
                    SessionActivity.shared.preferenceChanged(enabled: enabled)
                }

            Controls.divider

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

    /// Not a control: there is nothing to switch, the banner is raised because a shell stopped. The state printed is the system permission, not our preference; a row saying On beside a refused permission would claim something the app cannot do. On a plan without it the tap opens the paywall through ``PlanLocked``.
    private var notificationsSection: some View {
        let included = model.storeManager.access.includes(.terminalAlerts)

        return Controls.card(
            String(localized: "Notifications"),
            footer: included
                ? String(localized: "A shell that stops for an answer puts a banner up while Peering is not in front of you, on this device and through the Mac when no session is open. iOS carries the permission under Settings, Notifications, Peering.")
                : String(localized: "Being told when a terminal needs you is part of \(PlanCapability.terminalAlerts.minimumPlan.name), with sound from the Mac, Picture in Picture and files that move both ways.")
        ) {
            PlanLocked(capability: .terminalAlerts, title: String(localized: "Told when a shell needs you")) {
                Controls.row(String(localized: "Terminal needs you"), systemImage: "bell.badge") {
                    Text(model.notificationsAuthorized ? "On" : "Off")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Controls.divider

            // The device's half of the same question: a Mac reaches this phone with no session through a push to a token iOS gives it, and a missing token looks from the Mac like a failed send. A reason is shown when there is one, as the only place this failure is visible.
            Controls.row(String(localized: "This phone can be reached"), systemImage: "antenna.radiowaves.left.and.right") {
                Text(model.pushRegistration ?? "No")
                    .font(.subheadline)
                    .foregroundStyle(model.pushRegistration == nil ? .secondary : ColorPalette.caution)
            }
        }
    }

    private var trustedMacsSection: some View {
        Controls.card(String(localized: "Trusted Macs")) {
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

    /// The reset button is gone on purpose: the relay counts free minutes against the client ID, so a fresh identity handed out a fresh free allowance. Do not put it back.
#if DEBUG
    /// Behind `#if DEBUG`: not in any build a user receives (`Tools/install-iphone.sh` builds Debug). It changes the app and not the wire: gates read ``StoreManager/access``, which this overrides, while a session still states ``StoreManager/relayPlan`` from the real entitlement, so it cannot be used to spend relay allowance.
    private var developerSection: some View {
        Controls.card(
            String(localized: "Developer"),
            footer: String(localized: """
                Changes what this app shows, not what the relay is told: sessions stay metered at \
                whatever this Apple Account pays for.
                """)
        ) {
            Controls.row(String(localized: "Plan override"), systemImage: "hammer") {
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
                        Text(model.storeManager.planOverride?.name ?? String(localized: "Real"))
                            .foregroundStyle(model.storeManager.planOverride == nil ? .secondary : .primary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .tint(.white.opacity(0.72))
                .font(.subheadline)
                .accessibilityLabel("Plan override")
                .accessibilityValue(model.storeManager.planOverride?.name ?? String(localized: "Real"))
            }
        }
    }
#endif

    private var identitySection: some View {
        Controls.card(
            String(localized: "Device identity"),
            footer: String(localized: "How Macs recognise this device. Created once, on first launch.")
        ) {
            Controls.row(String(localized: "Device ID"), systemImage: "number") {
                Text(model.device.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Controls.divider

            Controls.row(String(localized: "Private key"), systemImage: "key.fill") {
                Text("P-256 · in Keychain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Controls.divider

            Controls.row(String(localized: "Paired Macs"), systemImage: "macbook") {
                Text("\(model.pairedHostIDs.count)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var moreSection: some View {
        Controls.card(String(localized: "More")) {
            // First: the Mac app is a download, so someone setting up another machine has to come back here for it.
            Link(destination: PeeringSite.download) {
                Controls.row(String(localized: "Peering for Mac"), systemImage: "arrow.down.circle") {
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
                Controls.row(String(localized: "Show introduction again"), systemImage: "rectangle.stack") {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(RailButtonStyle(scale: 0.99))

            Controls.divider

            // All five tours reset, with no way to pick: a skipped tip may have been read or dismissed mid-task, and the person who skipped it does not remember which.
            Button {
                Tour.resetAll()
            } label: {
                Controls.row(String(localized: "Show tips again"), systemImage: "lightbulb") {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(RailButtonStyle(scale: 0.99))

            Controls.divider

            // There is no analytics or crash reporting, so a report and an App Store review are the whole of the feedback. Diagnostics ride along as an attachment inside a draft the user can read and strip. `mailto:` cannot carry an attachment, so this opens Apple's compose sheet; with no Mail account it falls back to the plain link, unattached.
            Button {
                if MFMailComposeViewController.canSendMail() {
                    showingMailComposer = true
                } else {
                    openURL(Self.reportURL)
                }
            } label: {
                Controls.row(String(localized: "Report an issue"), systemImage: "envelope") {
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(RailButtonStyle(scale: 0.99))
            .foregroundStyle(ColorPalette.ink)
            .sheet(isPresented: $showingMailComposer) {
                MailComposer(
                    recipient: "support@getpeering.app",
                    subject: String(localized: "Peering issue"),
                    body: Self.reportBody,
                    attachment: (Data(Diagnostics.text(model: model).utf8), "text/plain", "diagnostics.txt"),
                    onFinish: { showingMailComposer = false }
                )
                .ignoresSafeArea()
            }

            Controls.divider

            Button {
                UIPasteboard.general.string = Diagnostics.text(model: model)
                copiedDiagnostics = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copiedDiagnostics = false
                }
            } label: {
                Controls.row(
                    String(localized: "Copy diagnostics"),
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

    /// A card of its own at the bottom. Both open in the browser, not a web view: a page inside the app would be a second copy of a document that must match the App Store listing's.
    private var legalSection: some View {
        Controls.card(String(localized: "Legal")) {
            externalLink(String(localized: "Privacy policy"), systemImage: "hand.raised", to: PeeringSite.privacy)

            Controls.divider

            externalLink(String(localized: "Terms of use"), systemImage: "doc.text", to: PeeringSite.terms)
        }
    }

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

    /// The app version and iOS release are the first things anyone has to ask for. The device ID, plan and path live in the ``Diagnostics`` attachment, not here.
    private static var reportBody: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"

        return """
            What happened:


            What I expected:


            Peering \(version) (\(build))
            \(ProcessInfo.processInfo.operatingSystemVersionString)
            """
    }

    /// The fallback when no Mail account is configured: `mailto:` has no attachment, so the "Copy diagnostics" row fills that gap by hand.
    private static var reportURL: URL {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "support@getpeering.app"
        components.queryItems = [
            URLQueryItem(name: "subject", value: String(localized: "Peering issue")),
            URLQueryItem(name: "body", value: reportBody),
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

/// Side by side and to scale (a medium widget is a little over twice a small's width and the same height), derived from the width the card has.
private struct HomeScreenWidgetPreview: View {
    let hostNames: [String]

    /// A medium widget is 338x158 points and a small is 158x158.
    private static let mediumToSmall: CGFloat = 2.14
    private static let gap: CGFloat = 12

    /// Seeded rather than measured on the first pass: `@State` starts at its declared value and the pair would otherwise be drawn once at the wrong size.
    @State private var smallSide: CGFloat = 94
    private static let design: CGFloat = 132

    private var primaryName: String { hostNames.first ?? String(localized: "Your Mac") }

    private var unit: CGFloat { smallSide / Self.design }

    var body: some View {
        HStack(alignment: .top, spacing: Self.gap) {
            column(String(localized: "Small")) { small }
            column(String(localized: "Medium")) { medium }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .frame(
            width: smallSide * Self.mediumToSmall,
            height: smallSide,
            alignment: .topLeading
        )
        .widgetPreviewSurface(radius: 24 * unit)
    }

    private var displayedNames: [String] {
        hostNames.isEmpty ? [String(localized: "Pair a Mac to connect")] : hostNames
    }
}

private extension View {
    /// The radius is passed in because the previews differ in size: a real widget's corner is about a sixth of its height.
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
