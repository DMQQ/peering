import RemoteCore
import SwiftUI

/// Choosing a Mac, and the ways that can fail.
///
/// Bonjour is the real path, but it is not the only one and it is not always available: in the
/// simulator it frequently finds nothing at all, and on a network that blocks multicast it
/// finds nothing anywhere. The manual address field is therefore a first-class path rather
/// than a debug affordance — the brief is explicit that a client whose only route in is a
/// discovery protocol it does not control has no route in.
struct HostPickerView: View {
    @Environment(SessionModel.self) private var model
    @State private var showsManualConnection = false

    /// The failure the user has already dismissed.
    ///
    /// The phase stays `.failed` until the next attempt, so without remembering the dismissal the
    /// dialog would reopen the instant it was closed.
    @State private var acknowledgedFailure: String?
    @State private var forgetTarget: String?

    /// The Mac being renamed, and what the field currently holds.
    @State private var renameTarget: String?
    @State private var renameDraft = ""

    /// Cleared by the footer's link, which is the only way back to the introduction once it has
    /// been dismissed. Read here so the link can exist at all — the flow itself reads the same
    /// key from `ContentView`, which is what actually shows it.
    @AppStorage(PreferenceKey.hasSeenWelcome) private var hasSeenWelcome = true

    private var failureAlert: Binding<Bool> {
        Binding(
            get: {
                guard let message = model.failureMessage else { return false }
                return message != acknowledgedFailure
            },
            set: { shown in
                if !shown { acknowledgedFailure = model.failureMessage }
            }
        )
    }

    var body: some View {
        @Bindable var model = model
        return NavigationStack {
            ZStack {
                ColorPalette.backdrop.ignoresSafeArea()

                // One soft light from the top. The backdrop is deliberately near-black, and a
                // single flat near-black reads as a hole rather than as a surface — this gives it
                // a direction without adding a colour, which is the one thing the palette does
                // not have.
                RadialGradient(
                    colors: [.white.opacity(0.07), .clear],
                    center: .top,
                    startRadius: 0,
                    endRadius: 460
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header

                        if let failure = model.identityFailure {
                            identitySection(failure)
                        }

                        nearbyCard
                        pairedCard
                        manualCard(address: $model.manualAddress, port: $model.manualPort)
                        footer
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 36)
                }

                if model.isBusy {
                    connectingOverlay
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Image(systemName: "waveform.path.ecg")
                    }
                    .accessibilityLabel("Diagnostics")
                }
            }
            // A connection that fails instantly and silently is indistinguishable from a button
            // that does not work — which is exactly how it was read. The failure text was always
            // there, in the phase and in the diagnostics; it just never reached the screen.
            .alert("Could not connect", isPresented: failureAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(model.failureMessage ?? "")
            }
            .alert("Forget this Mac?", isPresented: Binding(
                get: { forgetTarget != nil },
                set: { if !$0 { forgetTarget = nil } }
            )) {
                Button("Forget", role: .destructive) {
                    if let id = forgetTarget { model.forget(hostID: id) }
                    forgetTarget = nil
                }
                Button("Cancel", role: .cancel) { forgetTarget = nil }
            } message: {
                Text("This Mac will be removed from Trusted Macs. You can re-pair it at any time.")
            }
            .alert("Rename this Mac", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("Name", text: $renameDraft)
                Button("Save") {
                    if let id = renameTarget { model.rename(hostID: id, to: renameDraft) }
                    renameTarget = nil
                }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            } message: {
                // Said plainly, because the alternative is a user renaming a Mac here and then
                // looking for the new name on the Mac itself. This is a label for this phone.
                Text("The new name is only used on this iPhone. The Mac keeps its own name.")
            }
        }
    }

    /// The heading, and the one line that says whether anything is out there.
    ///
    /// The eyebrow above the title is why this is not just a wordmark: "are there any Macs?" is
    /// the question this screen exists to answer, and the answer is a discovery result that
    /// changes on its own. Putting it in the top-left corner means the screen says something
    /// before a single row has been read.
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Circle()
                    .fill(ColorPalette.ink.opacity(model.hosts.isEmpty ? 0.3 : 1))
                    .frame(width: 6, height: 6)
                Text(eyebrow)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .tracking(1.3)
                    .foregroundStyle(.secondary)
            }

            Text("Peering")
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .tracking(-1.5)

            Text("Your Mac, right here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            DeviceLinkArtwork()
                .frame(height: 132)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 14)
        .animation(Motion.tap, value: model.hosts.isEmpty)
    }

    /// What the dot is saying. The one thing worth knowing before reading any of the cards.
    private var eyebrow: String {
        if model.isBusy { return "CONNECTING" }
        if model.hosts.isEmpty { return "LOOKING FOR MACS" }
        return model.hosts.count == 1 ? "1 MAC NEARBY" : "\(model.hosts.count) MACS NEARBY"
    }

    /// What a connection looks like while it is being made.
    ///
    /// A tap on a Mac used to dim the list and change one word of eyebrow text, which is a very
    /// quiet answer to the loudest thing the app does. Connecting is a second of a TLS handshake
    /// and a certificate exchange with nothing to look at, and a second is long enough to wonder
    /// whether the tap registered.
    ///
    /// So it says which Mac, says what is happening, and dims the list behind it — the dimming is
    /// the part that matters, because it is what shows the row that was tapped is no longer the
    /// thing being looked at. It fades rather than springs, unlike everything else here: this is
    /// not a control answering a finger, it is a wait, and a wait that bounces reads as busywork.
    private var connectingOverlay: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(ColorPalette.ink)

                VStack(spacing: 3) {
                    Text(model.hostName ?? "Your Mac")
                        .font(.headline)
                        .lineLimit(1)
                    Text("Connecting…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(28)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .transition(.opacity.animation(.easeOut(duration: 0.2)))
        .allowsHitTesting(true)
    }

    /// The small print, and the claim the app is built on.
    ///
    /// The claim used to read "No account, no server. Everything stays on your network." The
    /// first half was true and the second was not: the Mac holds a connection open to the relay
    /// by default so it can be reached from away from home, which is the feature and not a bug —
    /// but it does mean a server is involved, and a footer that says otherwise is the kind of
    /// small dishonest sentence that costs an app its credibility the moment a user finds out.
    /// What is true is stated instead, and ``FAQView`` has the rest.
    private var footer: some View {
        VStack(spacing: 5) {
            Text(model.thisDeviceDescription)
                .font(.caption2.monospaced())
                // The one line here that is genuinely small print, and the only one that stays
                // at tertiary. It is an identifier, not a sentence.
                .foregroundStyle(.tertiary)

            Text("No account, nothing stored. Direct on your own network, relayed only when your Mac is somewhere else.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            VStack(spacing: 2) {
                NavigationLink {
                    FAQView()
                } label: {
                    Text("How Peering works")
                        .font(.caption2.weight(.medium))
                }
                .buttonStyle(RailButtonStyle(scale: 0.98))

                Button("Show the introduction again") {
                    hasSeenWelcome = false
                }
                .font(.caption2.weight(.medium))
                .buttonStyle(RailButtonStyle(scale: 0.98))
            }
            // Blue, the same blue the manual-connect row above uses for the one thing on it that
            // is a control. Everything here was tertiary, which is a shade chosen for text that
            // is not meant to be read closely — and then two buttons were put in it, at the
            // bottom of a screen, where nothing is legible at arm's length.
            .foregroundStyle(ColorPalette.accent)
            .padding(.top, 5)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var nearbyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionLabel("Nearby", systemImage: "dot.radiowaves.left.and.right")
                Spacer()
                Button { model.restartBrowsing() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(ColorPalette.surface, in: Circle())
                }
                .buttonStyle(RailButtonStyle())
                .accessibilityLabel("Search again")
            }

            if model.hosts.isEmpty {
                HStack(spacing: 12) {
                    ProgressView().tint(ColorPalette.ink)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Looking for Macs")
                            .font(.subheadline.weight(.semibold))
                        Text(model.browseStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 6)
            } else {
                VStack(spacing: 8) {
                    ForEach(model.hosts) { host in
                        Button { model.connect(to: .discovered(host)) } label: { hostRow(host) }
                            .buttonStyle(.plain)
                            .disabled(model.isBusy || !isCompatible(host))
                    }
                }
                Text(model.browseStatus).font(.caption).foregroundStyle(.secondary)
            }
        }
        .cardSurface()
    }

    private func manualCard(address: Binding<String>, port: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup(isExpanded: $showsManualConnection) {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        TextField("Mac address", text: address)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .textFieldStyle(.plain)
                            .padding(12)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                        TextField("Port", text: port)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.plain)
                            .padding(12)
                            .frame(width: 88)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    }
                    Button { model.connectToManualAddress() } label: {
                        Label("Connect", systemImage: "arrow.right")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ColorPalette.ink)
                    .foregroundStyle(.black)
                    .disabled(model.isBusy || model.manualAddress.isEmpty)
                }
                .padding(.top, 12)
            } label: {
                sectionLabel("Connect by address", systemImage: "network")
            }
        }
        .cardSurface()
    }

    private var pairedCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("Trusted Macs", systemImage: "checkmark.shield")

            if model.pairedHostIDs.isEmpty {
                HStack(spacing: 12) {
                    iconTile("shield")
                    Text("A Mac appears here after your first secure pairing.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            } else {
                VStack(spacing: 8) {
                    ForEach(model.pairedHostIDs, id: \.self) { hostID in
                        pairedRow(hostID)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    /// A Mac this device has already paired with.
    ///
    /// Tappable, so it is one tap away rather than something to wait for in the Nearby list.
    /// Discovery still has to find it — see ``SessionModel/connectToTrusted(hostID:)`` — but the
    /// request is remembered, so one tap is enough.
    ///
    /// Dressed as the same object as a Nearby row, because it *is* the same Mac seen twice: what
    /// separates the two cards is whether this device has paired before, not what is at the far
    /// end of the connection.
    ///
    /// "Forget" is deliberately quiet rather than red. Nothing else on this screen has a hue —
    /// the palette is brightness and nothing else — and a regular-weight button under the thumb
    /// is a poor thing to put next to an action with no undo.
    private func pairedRow(_ hostID: String) -> some View {
        let isOnline = model.hosts.contains { $0.id == hostID }
        return HStack(spacing: 10) {
            Button { model.connectToTrusted(hostID: hostID) } label: {
                HStack(spacing: 12) {
                    ZStack(alignment: .bottomTrailing) {
                        iconTile("macbook")
                        Circle()
                            // Green = visible on LAN right now. Gray = not detected nearby
                            // (may still be reachable via relay).
                            .fill(isOnline ? Color.green : Color.white.opacity(0.25))
                            .frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(ColorPalette.backdrop, lineWidth: 1.5))
                            .offset(x: 2, y: 2)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.displayName(forHostID: hostID) ?? "A Mac")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(pairedRowDetail(hostID: hostID, isOnline: isOnline))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    if model.isWaitingForHost {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy)

            Button("Forget") { forgetTarget = hostID }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red.opacity(0.85))
                .buttonStyle(RailButtonStyle())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .rowSurface()
        // Long press rather than a third button on the row. Connecting is what a tap means here
        // and it has to keep meaning that; renaming is the rare case, and a row with three
        // targets on it is a row nobody can hit the right part of in a hurry.
        .contextMenu {
            Button("Rename…") {
                renameDraft = model.displayName(forHostID: hostID) ?? ""
                renameTarget = hostID
            }
        }
    }

    /// The second line of a trusted row: online/offline status, last-session time, or
    /// the ID prefix when two Macs share the same name.
    private func pairedRowDetail(hostID: String, isOnline: Bool) -> String {
        let name = model.displayName(forHostID: hostID) ?? "A Mac"
        let sharesItsName = model.pairedHostIDs.contains {
            $0 != hostID && (model.displayName(forHostID: $0) ?? "A Mac") == name
        }
        if sharesItsName { return String(hostID.prefix(8)) }
        if isOnline { return "Nearby · tap to connect" }
        if let last = model.lastConnectedAt[hostID] {
            return "Last used " + RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date())
        }
        return "Tap to connect"
    }

    // MARK: - Rows

    /// A card's heading: small, tracked, and above the thing it names.
    ///
    /// Uppercase at the same size as the eyebrow in the header, so every label on the screen is
    /// one voice rather than a headline here and a caption there.
    private func sectionLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .tracking(1.1)
        }
        .foregroundStyle(.secondary)
    }

    /// The square a row's symbol sits in.
    private func iconTile(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(ColorPalette.ink)
            .frame(width: 42, height: 42)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(ColorPalette.ink.opacity(0.12))
            }
    }

    private func hostRow(_ host: DiscoveredHost) -> some View {
        HStack(spacing: 12) {
            iconTile("macbook")

            VStack(alignment: .leading, spacing: 2) {
                Text(host.name)
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 6) {
                    Text(host.id.prefix(8))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    if host.interfaceCount > 1 {
                        Text("· \(host.interfaceCount) interfaces")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 8)

            if let version = host.protocolVersion, version != ProtocolInfo.version {
                // Shown rather than hidden, and the row is disabled: connecting would fail
                // after a TLS handshake, which is a slow way to learn something the TXT
                // record already said.
                // A filled chip rather than a coloured one: this is the only row on the screen
                // that cannot be tapped, so it has to look different rather than merely say
                // something different.
                Text("v\(version)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(ColorPalette.selectedFill, in: Capsule())
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .rowSurface()
        .contentShape(Rectangle())
    }

    private func identitySection(_ failure: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("This device has no identity", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(ColorPalette.ink)
            Text(failure)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Reset identity") { model.resetDeviceIdentity() }
        }
        .cardSurface()
    }

    /// Whether the advertised protocol version is one this app can speak.
    ///
    /// An absent version is treated as compatible: older hosts publish only the device ID, and
    /// refusing them would hide a Mac that works perfectly well.
    private func isCompatible(_ host: DiscoveredHost) -> Bool {
        guard let version = host.protocolVersion else { return true }
        return version == ProtocolInfo.version
    }
}

/// The picture at the top: a Mac, a phone, and the link between them.
///
/// Two devices and three dots rather than anything literal, because the app's whole claim is in
/// that gap — the dots are the connection, and they are drawn at the same opacity the app uses
/// everywhere else for "this is on".
private struct DeviceLinkArtwork: View {
    /// How far a device drifts from centre, in points.
    ///
    /// Small and *bounded*: the card is sized to the tallest device plus twice this, so no
    /// amount of drift can carry one past an edge.
    private static let drift: CGFloat = 5

    private static let cardHeight: CGFloat = 132

    /// Where the phone sits in its cycle relative to the Mac's, as a fraction of its period.
    ///
    /// The two are deliberately out of step — a Mac and a phone that rose and fell together
    /// would read as one object breathing rather than two devices reaching for each other.
    private static let phonePhase = 0.35

    var body: some View {
        // The motion is computed from a clock rather than handed to SwiftUI as an animation, and
        // that is load-bearing rather than a style preference.
        //
        // `.animation(_:value:)` with `repeatForever` reads as the obvious tool here and is not
        // safe in this position: the modifier covers *every* animatable change in the subtree
        // beneath it, so it does not capture only the offset it was written for — it captures the
        // devices' own sizing too, and repeating that makes them grow and shrink forever. An
        // `.animation` on an ancestor then captures the whole thing a second time. That is how a
        // five-point float turns into devices walking out of the card.
        //
        // A value derived from `timeline.date` has no animation to capture, re-time or restart,
        // and its amplitude is a number this file can bound rather than one SwiftUI derives.
        TimelineView(.animation) { context in
            let now = context.date.timeIntervalSinceReferenceDate

            ZStack {
                card

                HStack(spacing: 26) {
                    mac
                        .offset(y: Self.wave(now, period: 5.2) * Self.drift)
                    dots(at: now)
                    phone
                        .offset(y: Self.wave(now, period: 6.4, phase: Self.phonePhase) * Self.drift)
                }
                .offset(x: -3, y: -2)
            }
        }
        .frame(height: Self.cardHeight)
        .accessibilityHidden(true)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [.white.opacity(0.06), .white.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.16), .white.opacity(0.03)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            }
            // Stated rather than left to the ZStack to infer, so the card is exactly the box the
            // drift above is bounded against.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var mac: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.white.opacity(0.12))
                .frame(width: 122, height: 78)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(ColorPalette.surface)
                        .padding(4)
                        .overlay {
                            Image(systemName: "cursorarrow.motionlines")
                                .font(.system(size: 21, weight: .medium))
                                .foregroundStyle(ColorPalette.ink)
                        }
                }
            Capsule()
                .fill(.white.opacity(0.18))
                .frame(width: 142, height: 6)
                .offset(y: 6)
        }
    }

    private var phone: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(.white.opacity(0.13))
            .frame(width: 50, height: 94)
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(ColorPalette.ink.opacity(0.55), lineWidth: 1.5)
                    .padding(4)
            }
    }

    /// The link itself: three dots lighting in sequence, which is the whole claim of the screen.
    ///
    /// Each is a quarter-second behind the last, and the curve spans the same 0.2–0.9 the rest of
    /// the app uses for "this is on".
    private func dots(at now: TimeInterval) -> some View {
        HStack(spacing: 5) {
            ForEach(Array([CGFloat(4), 5, 6].enumerated()), id: \.offset) { index, diameter in
                Circle()
                    .fill(ColorPalette.ink)
                    .frame(width: diameter, height: diameter)
                    .opacity(0.55 + 0.35 * Self.wave(
                        now,
                        period: 1.5,
                        phase: -Double(index) * (0.25 / 1.5)
                    ))
            }
        }
    }

    /// A value in `-1...1` cycling with `period` seconds, shifted `phase` of the way along.
    ///
    /// A sine rather than a triangle so the turnaround is soft at both ends; `easeInOut` was
    /// standing in for exactly this shape.
    private static func wave(_ now: TimeInterval, period: Double, phase: Double = 0) -> CGFloat {
        CGFloat(sin(2 * .pi * (now / period + phase)))
    }
}


/// Everything that is useful when something has gone wrong and noise otherwise.
struct DiagnosticsView: View {
    @Environment(SessionModel.self) private var model

    var body: some View {
        List {
            Section("Connection") {
                LabeledContent("Mac", value: model.hostName ?? "None")
                LabeledContent("State", value: state)
                LabeledContent("Path", value: model.connectionPath?.rawValue ?? "None")
                LabeledContent("Display", value: model.videoStatus)
                if let tls = model.tlsDescription {
                    LabeledContent("Transport", value: tls)
                }
                if let latency = model.latencyMilliseconds {
                    LabeledContent("Control latency", value: "\(Int(latency.rounded())) ms")
                }
                LabeledContent("Source", value: model.activeSourceID ?? "None")
            }

            Section("This device") {
                Text(model.thisDeviceDescription)
                    .font(.footnote.monospaced())
            }

            Section("Log") {
                if model.notes.isEmpty {
                    Text("Nothing yet").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.notes.enumerated()), id: \.offset) { _, note in
                        Text(note).font(.caption)
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
    }

    private var state: String {
        switch model.phase {
        case .idle: return "Idle"
        case .connecting: return "Connecting"
        case .handshaking: return "Handshaking"
        case .confirming: return "Confirming the pairing code"
        case .ready: return "Connected"
        case .failed(let message): return "Failed: \(message)"
        case .disconnected: return "Disconnected"
        }
    }
}
