import MacCastKit
import RemoteCore
import SSHCore
import SwiftUI
import UIKit


extension HomeTab {
    var showsUnacknowledgedFailure: Bool {
        guard let message = model.failureMessage else { return false }
        return message != acknowledgedFailure
    }

    var failurePresentation: FailurePresentation {
        let detail = model.failureMessage ?? "The connection could not be completed."
        guard model.connectionPath == .relay else {
            return FailurePresentation(title: "Could not connect", message: detail, isRelayFailure: false)
        }

        let normalized = detail.lowercased()

        // A first pairing that found nothing at the ID it was given. The relay answers the
        // same way whether the Mac is asleep or the ID was mistyped, and the ID is the half
        // the user can check, so it is named here rather than in the sentence beside it —
        // which was written for a Mac this device has paired with and knows.
        if let pairingID = model.remotePairingHostID,
           normalized.contains("not currently registered with the relay") {
            return FailurePresentation(
                title: "No Mac answered",
                message: "Nothing is registered with the relay under \(pairingID). Check that the whole ID was copied or scanned from the Mac, and that the Mac is awake with Peering running.",
                isRelayFailure: false
            )
        }

        if normalized.contains("not currently registered with the relay") {
            return FailurePresentation(
                title: "Mac is not available",
                message: "The relay is working, but this Mac is not connected to it. Make sure the Mac is awake and Peering is running there.",
                isRelayFailure: false
            )
        }

        // Matched on the word the sentence itself uses, which is the shape all of this file has:
        // the session hands over a sentence and the screen decides what to call it. The one
        // sentence this looks for is `Failure.pinMismatch`'s, and it is the *only* thing that
        // produces it. The connect path used to raise the same alarm for any failure on a paired
        // Mac, which is why this check has a second, now dead spelling removed from it.
        if normalized.contains("pinned") {
            return FailurePresentation(title: "Mac identity changed", message: detail, isRelayFailure: false)
        }

        // The relay found a Mac, and it is not the one whose ID was dialled: the wrong screen
        // was scanned, or the ID was typed wrong in a way that still spelled a real Mac. The
        // sentence from the session already names both IDs, so it stands on its own.
        if normalized.contains("a different mac answered") {
            return FailurePresentation(title: "Wrong Mac", message: detail, isRelayFailure: false)
        }

        // The relay refuses a pair whose versions differ before either end spends a handshake on
        // it, and it says so with both numbers — so the side that needs updating is worked out
        // here rather than assumed. It used to say "update the Mac" whatever had happened, which
        // is wrong half the time and sends the user to the one device that cannot help them.
        if normalized.contains("host speaks v") {
            let host = Self.version(in: normalized, after: "host speaks v")
            let client = Self.version(in: normalized, after: "client speaks v")
            if let host, let client, client < host {
                return FailurePresentation(
                    title: "Update this device's app",
                    message: "The Mac is running a newer version of Peering than this app. Update Peering from the App Store, then connect again.",
                    isRelayFailure: false
                )
            }
            return FailurePresentation(
                title: "Update Peering on the Mac",
                message: "The Mac is running an older version of Peering than this app. Update it there, then pair again.",
                isRelayFailure: false
            )
        }

        return FailurePresentation(
            title: "Remote connection unavailable",
            message: "Peering could not complete the connection through the relay. Your Mac may be working normally. If both devices are nearby, put them on the same network and connect from Nearby.\n\nDetail: \(detail)",
            isRelayFailure: true
        )
    }

    // MARK: Cards

    var connectionFailureCard: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 5) {
                Text(failurePresentation.title)
                    .font(.subheadline.weight(.semibold))
                Text(failurePresentation.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if failurePresentation.isRelayFailure {
                    Button("Search nearby") { model.restartBrowsing() }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            Spacer(minLength: 0)
            Button {
                acknowledgedFailure = model.failureMessage
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .cardSurface()
    }

    /// The Connect tab's one card, in the order the screen is read: what is here now, what to do
    /// when it is not here, and last the Macs already known.
    ///
    /// The stored ones go last rather than in the middle. They are the answer to "where is my
    /// Mac", which is the question asked *after* the two above have not produced it — and a list
    /// that grows with every Mac ever paired should push nothing below it as it grows.
    var connectionsSection: some View {
        VStack(spacing: 0) {
            // The three sections of the one card are what the first-run tips are drawn around,
            // each on its own: what is on this network, the way in for a Mac that is not, and what
            // has been paired with before. Anchored after the padding rather than before it, so the
            // highlight rings the block the eye sees rather than the text inside it.
            nearbyCardContent
                .padding(16)
                .tourAnchor(.connectNearby)
            Divider()
                .overlay(Color.white.opacity(0.1))
            remotePairingEntry
                .padding(16)
                .tourAnchor(.connectRemote)
            Divider()
                .overlay(Color.white.opacity(0.1))
            pairedCardContent
                .padding(16)
                .tourAnchor(.connectTrusted)
        }
        .cardBackground()
    }

    var nearbyCardContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                sectionLabel("Nearby", systemImage: "dot.radiowaves.left.and.right")
                if model.hosts.isEmpty {
                    ProgressView()
                        .scaleEffect(0.65)
                        .tint(.secondary)
                }
                Spacer()

                Button { showsManualConnection = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "network")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Connect by address")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(ColorPalette.surface, in: Capsule())
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(RailButtonStyle())

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

            // The rows, and under them what the browser is saying. The line is drawn in both states
            // rather than once inside each of them: as a pair of branches it was a different view
            // either side of the first Mac arriving, and the two sentences cross-faded through each
            // other in the same place.
            if !model.hosts.isEmpty {
                VStack(spacing: 8) {
                    ForEach(model.hosts) { host in
                        // **A Mac this device has never paired with is a pairing, and a pairing
                        // past the first is `extraMacs`.** A Mac already in the trusted list is
                        // not: that is a reconnect, and it stays free on every plan along with
                        // every other thing about connecting to a Mac you own. The two are
                        // told apart by the pin store, which is what decides whether the tap
                        // below is about to write a second pairing or to resume an existing one.
                        let isNewPairing = !model.pairedHostIDs.contains(host.id)
                        // And compatible, so the badge never stands on a row that could not have
                        // connected anyway: a Mac running an older protocol shows UPDATE and stays
                        // untappable, because "buy Relay" is not the answer to it.
                        let locked = isNewPairing && !canPairAnotherMac && isCompatible(host)

                        // The row is the control, so the locked form is the row itself with the
                        // plan's name over its trailing edge. It keeps its name, its ID and its
                        // tile: on this list the tile and the name are how a user finds the Mac
                        // they are trying to reach, and a row that had been replaced by a badge
                        // would be a Mac that had disappeared from a list of Macs.
                        PlanLocked(
                            capability: .extraMacs,
                            title: model.displayName(forHostID: host.id) ?? host.name,
                            placement: .trailing,
                            diameter: 26,
                            isIncluded: !locked
                        ) {
                            Button {
                                model.connect(to: .discovered(host))
                            } label: {
                                hostRow(host)
                            }
                            .buttonStyle(.plain)
                            .disabled(model.isBusy || !isCompatible(host))
                        }
                        // A Mac that turned up on this network is given the moment it takes to be
                        // seen turning up, rather than snapping into a list somebody is reading.
                        .transition(Self.hostArrival)
                    }
                }
            }

            Text(model.browseStatus)
                .font(.caption)
                .foregroundStyle(model.hosts.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .padding(.vertical, model.hosts.isEmpty ? 4 : 0)
        }
        // On the container rather than on each row: a Mac arriving moves the rows around it, and a
        // transition cannot move a neighbour.
        .animation(reduceMotion ? nil : Motion.settle, value: model.hosts)
    }

    /// How a Mac arrives in the Nearby list.
    ///
    /// A fade and eight points of rise, and the rise is the whole of it. This list is fed by
    /// discovery, so a row is a Mac that turned up rather than one that was placed, and a full
    /// slide from the row's own height, which is what `.move` gives, would read as a list being
    /// rearranged rather than as a name appearing in it.
    private static let hostArrival = AnyTransition.modifier(
        active: HostArrival(progress: 0),
        identity: HostArrival(progress: 1)
    )

    /// The way in for a Mac that discovery cannot produce and never will.
    ///
    /// Its own section rather than another row under Nearby, because the two are mutually
    /// exclusive answers: Nearby is where the Mac is on this network, and this is for when it
    /// is not on any network this phone can see. It sits between Nearby and the stored Macs
    /// for the same reason: it is the second thing to try, and the Macs already paired are the
    /// answer once both of those have not produced one.
    var remotePairingEntry: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("Another network", systemImage: "globe")

            // **The second way to pair a Mac, and it counts the same.** The pin store is the
            // one list of paired Macs, so a Mac paired by an ID typed from another network is
            // on it exactly like one picked out of Nearby, which is why the limit is asked
            // here as well. The limit is what is locked, not the row: the first Mac is free on
            // every plan, so ``canPairAnotherMac`` is the question and the map alone would take
            // away the free one.
            //
            // The row itself is the control, so the locked form is this row dimmed with the plan's
            // name over its trailing edge, and the tap opens the plans rather than a sheet that
            // would be refused at the end of it.
            PlanLocked(
                capability: .extraMacs,
                title: "Pair with a Mac elsewhere",
                placement: .trailing,
                diameter: 26,
                isIncluded: canPairAnotherMac
            ) {
                Button {
                    showsRemotePairing = true
                } label: {
                    HStack(spacing: 12) {
                        IconTile(symbol: "number")

                        VStack(alignment: .leading, spacing: 3) {
                            // Two short lines rather than three long ones. The old title said the
                            // whole thing — "a Mac that is not on your network" — and the sentence
                            // under it said it again with the device ID in it, which made a section
                            // about one button the tallest thing on the screen.
                            Text("Pair with a Mac elsewhere")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(ColorPalette.ink)
                                .multilineTextAlignment(.leading)
                            Text(canPairAnotherMac
                                 ? "Type or scan the device ID shown on it."
                                 : "One Mac is free. \(PlanCapability.extraMacs.minimumPlan.name) pairs with every Mac you own.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }

                        // The spacer stays and the chevron that followed it does not: the row still
                        // has to reach the far edge for its tap target, and the pairing sheet it
                        // opens is something you come back from rather than somewhere the row
                        // leads.
                        //
                        // **It was also meant to be the room the badge lands in, and a spacer
                        // cannot be that.** A spacer keeps a minimum and gives the rest away, so
                        // the sentence beside it — which wants every point it can get — took the
                        // badge's width first and the mark came down on its last line. What holds
                        // the room instead is a hidden copy of the badge itself, because the width
                        // of RELAY in a capsule is the font's business and a number standing in
                        // for it is a second copy of that answer. The row still reaches the edge
                        // of its card: what the room narrows is the sentence, not the surface, and
                        // the mark is drawn over this copy by ``PlanLocked`` rather than in its
                        // place.
                        if canPairAnotherMac {
                            Spacer(minLength: 8)
                        } else {
                            PlanLock(capability: .extraMacs, diameter: 26).hidden()
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .rowSurface()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
                .opacity(model.isBusy ? 0.5 : 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var pairedCardContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("Trusted Macs", systemImage: "checkmark.shield")

            if model.pairedHostIDs.isEmpty {
                HStack(spacing: 12) {
                    IconTile(symbol: "shield")
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
    }

    var firstPairingCard: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: "wifi")

            VStack(alignment: .leading, spacing: 4) {
                Text("First connection")
                    .font(.subheadline.weight(.semibold))
                Text("On the same network, choose your Mac from Nearby. If it is somewhere else, pair with the device ID from Devices in Peering on the Mac. Someone has to be at the Mac either way: it shows six digits and you enter them here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // **This card is read before anything in the app can work, which is why the link
                // belongs on it.** The Mac app is a download rather than an App Store install, so
                // somebody who has just installed this half has no way from inside it to find the
                // other one: Nearby is empty because no Mac is listening, and the paragraph above
                // names "Peering on the Mac" without saying where that comes from.
                // Drawn the way the app draws its other secondary actions, rather than as tinted
                // text: there is no accent hue in this app except for "this is on", and a link
                // coloured with it would be borrowing a state to mean "tap me". See ``ColorPalette``.
                Link(destination: PeeringSite.download) {
                    Label("Get Peering for Mac", systemImage: "arrow.down.circle")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 4)
            }

            Spacer(minLength: 0)
        }
        .cardSurface()
    }

    var securityCard: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "faceid")

            VStack(alignment: .leading, spacing: 3) {
                Text("Protect paired Macs")
                    .font(.subheadline.weight(.semibold))
                Text("Ask for \(DeviceAuthentication.biometryName), or your device passcode, when Peering is opened again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: Binding(
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
            .labelsHidden()
            .disabled(!DeviceAuthentication.isAvailable)
        }
        .cardSurface()
    }

    // MARK: Tips

    /// What this screen owes, which is nothing until it has finished arriving.
    ///
    /// **The gate is the entrance, and it is not politeness.** The cards a step is drawn around
    /// travel into place over half a second after the screen appears, and the frames a tour reads
    /// are frames of the real views: a ring measured off a card that is still on its way is a ring
    /// around where the card used to be. `sectionsVisible` is that journey being over, so the tips
    /// wait for the screen to be the screen before they describe it.
    ///
    /// An array rather than a flag, because a screen with more than one tour to its name (see
    /// ``SSHTerminalScreen``) has to say which of them come first, and "which" is the order.
    var dueConnectTours: [Tour] {
        guard !hasSeenTourConnect, sectionsVisible else { return [] }
        return [.connect]
    }

}

// MARK: - Supporting types

/// One row's arrival in the Nearby list, as a transition: transparent, and eight points below
/// where it lands.
private struct HostArrival: ViewModifier {
    /// 0 before the Mac has been found, 1 once it has arrived.
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .offset(y: (1 - progress) * 8)
    }
}

struct FailurePresentation {
    let title: String
    let message: String
    let isRelayFailure: Bool
}
