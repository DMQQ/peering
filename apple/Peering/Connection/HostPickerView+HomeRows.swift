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
            Button { model.connectToTrusted(hostID: hostID) } label: {
                HStack(spacing: 12) {
                    ZStack(alignment: .bottomTrailing) {
                        IconTile(symbol: "macbook")
                        // Filled for a Mac known to be up, hollow for unknown: a grey filled dot made one mark mean both off and unchecked.
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
                        Text(model.displayName(forHostID: hostID) ?? String(localized: "A Mac"))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(pairedRowDetail(hostID: hostID, reach: reach, isActive: isActive))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    // No chevron: tapping connects, an action rather than a place.
                    if model.isWaitingForHost {
                        ProgressView().controlSize(.mini)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Not disabled for the open Mac, for the reason it is not gated: this is the way back to it.
            .disabled(model.isBusy && !isActive)

            Menu {
                Section("Connection") {
                    Button {
                        model.connectToTrustedOverLAN(hostID: hostID)
                    } label: {
                        Label("Connect via LAN", systemImage: "wifi")
                    }
                    // Only when Bonjour can see it: a Mac the relay says is up cannot necessarily be dialled on the LAN.
                    .disabled(reach != .nearby || model.isBusy)

                    Button {
                        model.connectToTrustedOverRelay(hostID: hostID)
                    } label: {
                        Label("Connect via Relay", systemImage: "network")
                    }
                    .disabled(!model.allowsRelay || model.isBusy)

                    // Drawn whatever the Mac's state: dropping it for a Mac with no address on file hid it in exactly the state the feature exists for.
                    let wakeRefusal = wakeRefusalReason(hostID: hostID, reach: reach)
                    Button {
                        model.wakeHost(id: hostID)
                    } label: {
                        // "on LAN" is in the name because the packet is a broadcast that never leaves the network; a Mac the relay sees is usually elsewhere.
                        Label("Wake Mac on LAN", systemImage: "power")
                    }
                    // A Mac known to be up needs no waking; one of unknown state is what this is for, so refusal is never about being switched off.
                    .disabled(wakeRefusal != nil)

                    if let wakeRefusal {
                        // An item of its own, not a Section footer: a menu drops captions and disabled items cannot carry subtitles. A `Button` because buttons are what a menu always draws; disabled so tapping closes the menu.
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

    /// Two of these four sentences are admissions, hence ``SessionModel/Reachability`` rather than a Bool: "Last used" says it has not found out whether the Mac is up, and even "Not reachable" is not "offline", since a Mac can be awake on its own network while registered nowhere.
    func pairedRowDetail(
        hostID: String,
        reach: SessionModel.Reachability,
        isActive: Bool
    ) -> String {
        let name = model.displayName(forHostID: hostID) ?? String(localized: "A Mac")
        let sharesItsName = model.pairedHostIDs.contains {
            $0 != hostID && (model.displayName(forHostID: $0) ?? String(localized: "A Mac")) == name
        }
        if sharesItsName { return String(hostID.prefix(8)) }

        if isActive {
            // "Tap to go back" is readable exactly when the picture is not on screen (see ``SessionModel/isSessionOnScreen``).
            let path = reach == .nearby ? String(localized: "Connected via LAN") : String(localized: "Connected via Relay")
            return model.isSessionOnScreen ? path : String(localized: "\(path) · tap to go back")
        }
        switch reach {
        case .nearby: return String(localized: "Nearby · tap to connect")
        case .viaRelay: return String(localized: "Online · tap to connect")
        case .notRegistered:
            guard let last = model.lastConnectedAt[hostID] else { return String(localized: "Not reachable") }
            return String(localized: "Not reachable · last used ")
                + RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date())
        case .unknown:
            if model.relayReachable == false {
                return String(localized: "Relay unavailable · connect over LAN")
            }
            if let last = model.lastConnectedAt[hostID] {
                return String(localized: "Last used ")
                    + RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date())
            }
            return model.allowsRelay ? String(localized: "Not nearby · will try relay") : String(localized: "Not nearby · LAN only")
        }
    }

    /// Two refusals with different fixes: a Mac seen up needs no wake (it passes on its own); a Mac with no address on file needs a connection first, as the address arrives in the host's hello. The address is asked first, so a Mac that falls asleep with no stored address does not show the item enabled with nothing to send.
    func wakeRefusalReason(hostID: String, reach: SessionModel.Reachability) -> String? {
        if model.hostMACAddresses[hostID]?.isEmpty ?? true { return String(localized: "No MAC address on file yet.") }
        if reach.isReachable { return String(localized: "That Mac is already awake.") }
        return nil
    }

    func hostRow(_ host: DiscoveredHost) -> some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                IconTile(symbol: "macbook")
                Circle()
                    .fill(Color.green)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(ColorPalette.backdrop, lineWidth: 1.5))
                    .offset(x: 2, y: 2)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Online")

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

            // A Mac this app cannot talk to is told what to do, not a version number (it stays in the diagnostics).
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

    /// Shown only while the key cannot be loaded or made. It used to offer a reset, which handed the relay a new client ID and so a new free allowance (see ``identitySection``). The model builds the identity in `init`, so the next launch is a real retry.
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

    /// A locked Keychain deletes nothing: the card clears itself once the pairings can be read. Damaged data cannot be read ever again, so that case offers the reset.
    var pinsUnreadableCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Your paired Macs could not be read", systemImage: "lock.fill")
                .foregroundStyle(ColorPalette.ink)
            if model.pinsNeedReset {
                Text("The pairings saved on this iPhone are damaged and cannot be read. Reset them to pair your Macs again. No new pairing is saved until then.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ResetPairedMacsButton(model: model)
                    .font(.caption.weight(.semibold))
            } else {
                Text("The iPhone's Keychain was not available. Unlock the iPhone and reopen Peering. Nothing has been removed, and no new pairing is saved until this is fixed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Dismiss") { model.pinsUnreadableNoticeShown = false }
                .font(.caption.weight(.semibold))
        }
        .cardSurface()
    }

    func sectionLabel(_ title: String, systemImage: String) -> some View {
        Controls.sectionLabel(title, systemImage: systemImage)
    }

    func isCompatible(_ host: DiscoveredHost) -> Bool {
        guard let version = host.protocolVersion else { return true }
        return version == ProtocolInfo.version
    }
}
