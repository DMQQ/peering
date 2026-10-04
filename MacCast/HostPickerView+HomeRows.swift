import MacCastKit
import RemoteCore
import SSHCore
import SwiftUI
import UIKit


extension HomeTab {
    // MARK: Rows

    func pairedRow(_ hostID: String) -> some View {
        let reach = model.reachability(ofHost: hostID)
        let isActive = model.currentHostID == hostID && model.phase == .ready
        return HStack(spacing: 10) {
            // **The second Mac is the paid one.** Drawn as itself with its own dot and its own
            // name, dimmed, with the plan's name at its trailing edge rather than a padlock in
            // the row's place: a row is how somebody finds out the app can hold more than one
            // Mac open at all, and the first Mac is free on every plan, which is why
            // `isIncluded` is passed rather than left to the map. See ``PlanLocked``.
            //
            // And a Mac that is open is not another Mac: this row is the way back to it, so the
            // concurrency gate is not this row's business and tapping it must not open the
            // paywall. See ``SessionModel/isSessionOnScreen``.
            PlanLocked(
                capability: .concurrentSessions,
                title: "Another Mac",
                placement: .trailing,
                diameter: 44,
                isIncluded: model.canAddAnotherSession || isActive
            ) {
            Button { model.connectToTrusted(hostID: hostID) } label: {
                HStack(spacing: 12) {
                    ZStack(alignment: .bottomTrailing) {
                        IconTile(symbol: "macbook")
                        // Filled for a Mac known to be up, hollow for one that is not known to be
                        // anything. A grey filled dot was the old drawing and it made the same
                        // mark mean "off" and "unchecked", which are different sentences.
                        Circle()
                            .fill(reach.isReachable || isActive ? Color.green : .clear)
                            .overlay(
                                Circle()
                                    .strokeBorder(
                                        Color.white.opacity(reach.isReachable || isActive ? 0 : 0.35),
                                        lineWidth: 1.5
                                    )
                            )
                            .frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(ColorPalette.backdrop, lineWidth: 1.5))
                            .offset(x: 2, y: 2)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.displayName(forHostID: hostID) ?? "A Mac")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(pairedRowDetail(hostID: hostID, reach: reach, isActive: isActive))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    // No chevron, and the row is where one used to be. Tapping this *connects*,
                    // which is an action rather than a place, so a chevron was a claim the row did
                    // not keep. It also sat beside the ellipsis menu, which made two trailing
                    // glyphs of which only one was a control.
                    if model.isWaitingForHost {
                        ProgressView().controlSize(.mini)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // And not disabled for the Mac that is open, for the same reason it is not gated:
            // this is the way back to it, and a row drawn live that does nothing when tapped is
            // worse than one that says it cannot be used. See ``SessionModel/isSessionOnScreen``.
            .disabled(model.isBusy && !isActive)
            }

            Menu {
                Section("Connection") {
                    Button {
                        model.connectToTrustedOverLAN(hostID: hostID)
                    } label: {
                        Label("Connect via LAN", systemImage: "wifi")
                    }
                    // Only when Bonjour can actually see it. A Mac the relay says is up is not one
                    // this can be dialled on the local network, which is the whole distinction
                    // between the two rows above it.
                    .disabled(reach != .nearby || model.isBusy)

                    Button {
                        model.connectToTrustedOverRelay(hostID: hostID)
                    } label: {
                        Label("Connect via Relay", systemImage: "network")
                    }
                    .disabled(!model.allowsRelay || model.isBusy)

                    // Drawn whatever the Mac's state, which it was not before: the item used to
                    // be dropped for a Mac with no address on file, and that is the state the
                    // feature exists for. A Mac this phone has never connected to is one whose
                    // row was quietly an item shorter than the feature list promises, with
                    // nothing on screen to say which item or why.
                    let wakeRefusal = wakeRefusalReason(hostID: hostID, reach: reach)
                    Button {
                        model.wakeHost(id: hostID)
                    } label: {
                        // "on LAN" is in the name and not only in the footnote below, because
                        // the packet is a broadcast and a broadcast never leaves the network it
                        // was sent on. A Mac the relay can see is usually somewhere else, and
                        // this is the one item in the menu that cannot be used from there.
                        Label("Wake Mac on LAN", systemImage: "power")
                    }
                    // A Mac known to be up has no reason to be woken, and one whose state is
                    // unknown is exactly the case this is for, so the refusal is never about
                    // being switched off.
                    .disabled(wakeRefusal != nil)

                    if let wakeRefusal {
                        // Said as an item of its own rather than a `Section` footer, because a
                        // disabled item cannot carry a subtitle and the menu renderer is the
                        // thing drawing this: a caption it silently drops is the same failure
                        // as the missing item, one layer further out. This is a `Button` and not
                        // a bare `Text` for the same reason, buttons being the one thing a menu
                        // is guaranteed to draw, and it is disabled so that tapping the
                        // explanation does nothing but close the menu.
                        Button {} label: {
                            Text(wakeRefusal)
                        }
                        .disabled(true)
                    }
                }

                Section {
                    Button("Rename…", systemImage: "pencil") {
                        renameDraft = model.displayName(forHostID: hostID) ?? ""
                        renameTarget = hostID
                    }
                    Button("Forget", systemImage: "trash", role: .destructive) {
                        forgetTarget = hostID
                    }
                    .menuDanger()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(RailButtonStyle())
            .menuInk()
            .accessibilityLabel("More connection options")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .rowSurface()
    }

    /// What the row says under the name.
    ///
    /// **Two of these four sentences are admissions**, and they are the reason this takes a
    /// ``SessionModel/Reachability`` rather than a `Bool`. "Last used Tuesday" is what this says
    /// when it has not found out whether the Mac is up, and it says it rather than "offline"
    /// because it does not know. "Not reachable" is the one case where the relay has actually
    /// answered, and it is still not the word "offline": a Mac can be awake and reachable on its
    /// own network while being registered nowhere.
    func pairedRowDetail(
        hostID: String,
        reach: SessionModel.Reachability,
        isActive: Bool
    ) -> String {
        let name = model.displayName(forHostID: hostID) ?? "A Mac"
        let sharesItsName = model.pairedHostIDs.contains {
            $0 != hostID && (model.displayName(forHostID: $0) ?? "A Mac") == name
        }
        if sharesItsName { return String(hostID.prefix(8)) }

        if isActive {
            // "Tap to go back" included, because this row is readable exactly when the picture is
            // not on screen: a session that is on screen has taken the whole screen, so the picker
            // and the picture cannot be up at once. See ``SessionModel/isSessionOnScreen``.
            let path = reach == .nearby ? "Connected via LAN" : "Connected via Relay"
            return model.isSessionOnScreen ? path : "\(path) · tap to go back"
        }
        switch reach {
        case .nearby: return "Nearby · tap to connect"
        case .viaRelay: return "Online · tap to connect"
        case .notRegistered:
            guard let last = model.lastConnectedAt[hostID] else { return "Not reachable" }
            return "Not reachable · last used "
                + RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date())
        case .unknown:
            if model.relayReachable == false {
                return "Relay unavailable · connect over LAN"
            }
            if let last = model.lastConnectedAt[hostID] {
                return "Last used "
                    + RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date())
            }
            return model.allowsRelay ? "Not nearby · will try relay" : "Not nearby · LAN only"
        }
    }

    /// Why the wake item cannot be pressed, or `nil` when it can.
    ///
    /// **Two refusals, because they are two different facts with two different fixes.** A Mac
    /// the relay or Bonjour can see is up, so a wake packet would be aimed at something already
    /// running, and that is a state which passes on its own. A Mac with no address on file is a
    /// gap in what this phone knows, and the only thing that closes it is a connection: the
    /// address arrives in the host's hello, so Peering has one for a Mac it has talked to and
    /// none for a Mac it has not.
    ///
    /// The address is asked about first, and deliberately. A Mac that is up with no address
    /// stored would otherwise show the item enabled the moment it fell asleep, with nothing to
    /// send, which is the tap that did nothing and taught nobody anything.
    func wakeRefusalReason(hostID: String, reach: SessionModel.Reachability) -> String? {
        if model.hostMACAddresses[hostID]?.isEmpty ?? true { return "No MAC address on file yet." }
        if reach.isReachable { return "That Mac is already awake." }
        return nil
    }

    /// Whether there is room on this plan for one more paired Mac.
    ///
    /// Free pairs with one and every paid plan pairs with every Mac you own, which makes this a
    /// question about the *list* rather than about the tap: the first pairing is free on every
    /// plan, and what costs is the second. Asked here rather than stored, so the two places that
    /// pair a Mac (this list and the row below it) answer the same way.
    var canPairAnotherMac: Bool {
        model.storeManager.access.includes(.extraMacs) || model.pairedHostIDs.isEmpty
    }

    func hostRow(_ host: DiscoveredHost) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: "macbook")

            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName(forHostID: host.id) ?? host.name)
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

            // A Mac this app cannot talk to, said as the thing to do about it rather than as a
            // number. "v12" beside a Mac that will not connect is a puzzle: the number means
            // nothing on its own, and the row is already dimmed, so what is left to say is what
            // to do. The number is still in the diagnostics, to whoever has to be told it.
            // The chevron that used to sit in the `else` here is gone. Tapping a discovered Mac
            // connects to it, so the row leads nowhere a chevron could honestly point at, and the
            // branch it lived in made the badge and the arrow two states of one slot rather than
            // one fact and one affordance.
            //
            // The protocol badge is the only thing left in that slot, and the plan badge is not
            // drawn here at all: it goes over the row's trailing edge from the outside (see the
            // ``PlanLocked`` around this row), so that the two badges are never the same slot
            // competing for one fact. A Mac that cannot be talked to shows UPDATE and is not
            // locked, which is the same rule as before and is now structural rather than decided.
            if let version = host.protocolVersion, version != ProtocolInfo.version {
                Text("UPDATE")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(ColorPalette.selectedFill, in: Capsule())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .rowSurface()
        .contentShape(Rectangle())
    }

    /// Shown only while the key cannot be loaded or made, which is the one state the app cannot
    /// pair its way out of. It used to offer a reset, which was the same button that handed the
    /// relay a new client ID and so a new free allowance — see ``identitySection`` in the Settings
    /// tab. What is left is the news and the one true next step: the model builds the identity in
    /// its `init`, so the next launch is a real retry rather than a hope.
    func identityFailureCard(_ failure: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("This device has no identity", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(ColorPalette.ink)
            Text(failure)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Nothing can be paired until this is fixed. Peering will try again the next time it starts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardSurface()
    }

    func manualSheet(address: Binding<String>, port: Binding<String>) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                // The screen's name in the display face rather than as a navigation title, which is
                // the trade ``RemotePairingSheet`` makes next door and for the same reason: an inline
                // title is set by iOS, in the system face, at a size iOS chooses.
                TabScreenHeader("Connect by Address")

                HStack(spacing: 10) {
                    TextField("Mac address", text: address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(
                            .white.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                    TextField("Port", text: port)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .frame(width: 88)
                        .background(
                            .white.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                }

                Button {
                    model.connectToManualAddress()
                    showsManualConnection = false
                } label: {
                    Label("Connect", systemImage: "arrow.right")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.borderedProminent)
                // Both states named rather than left to the style, which dims an ink fill to a grey
                // that a black label disappears into — the same trade the pairing sheet makes.
                .tint(canConnect ? ColorPalette.ink : .white.opacity(0.16))
                .foregroundStyle(canConnect ? ColorPalette.onInk : .white.opacity(0.55))
                .disabled(!canConnect)
            }
            .padding(24)
            .frame(maxHeight: .infinity, alignment: .top)
            // Nothing in the bar but the Cancel, and its own background off: this sheet is one
            // surface, and a grey strip across the top of it was the part that read as a piece of
            // iOS that had landed on the app.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { showsManualConnection = false }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        // Painted on the presentation rather than on the content, so it reaches behind the bar too.
        .presentationBackground(ColorPalette.backdrop)
        // Taller than it was by the header it now carries, and by the bar, which the header used to
        // share with a title.
        .presentationDetents([.height(268)])
        .preferredColorScheme(.dark)
    }

    /// Whether the sheet has an address to dial. Named because two things read it, the tint and the
    /// `disabled`, and those two disagreeing is a button that looks live and does nothing.
    var canConnect: Bool {
        !model.isBusy && !model.manualAddress.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Kept as a name here rather than replaced at three call sites, but it is now the shared
    /// one — the Servers tab draws the same heading, and two copies of a shape that appears on two
    /// screens is how they drift apart.
    func sectionLabel(_ title: String, systemImage: String) -> some View {
        Controls.sectionLabel(title, systemImage: systemImage)
    }

    /// The number after `marker` in a message like "host speaks v13, client speaks v12".
    ///
    /// Written as a fetch rather than a regex because the sentence is ours: the relay builds it,
    /// this app reads it, and the two live in one repository. If the phrasing ever changes, the
    /// parse returns nil and the failure falls back to blaming the Mac — which is the old
    /// behaviour, and no worse than it was.
    static func version(in message: String, after marker: String) -> Int? {
        guard let start = message.range(of: marker) else { return nil }
        let digits = message[start.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    func isCompatible(_ host: DiscoveredHost) -> Bool {
        guard let version = host.protocolVersion else { return true }
        return version == ProtocolInfo.version
    }
}
