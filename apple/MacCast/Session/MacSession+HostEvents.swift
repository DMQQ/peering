import MacCastKit
import RemoteCore
import SwiftUI

extension MacSession {
    func apply(hello: ServerHello) {
        // The host's own name is authoritative; Bonjour is only a hint and can be minutes stale.
        hostName = hello.hostName
        hostID = hello.serverID
        logHello(hello)
        // Recorded once at the door rather than guessed each time. See ``PicturePause/mayAsk(hostDeclared:)``.
        hostSupportsVideoPause = PicturePause.mayAsk(hostDeclared: hello.supportsVideoPause)
        hostSupportsAgentList = hello.supportsAgentList == true
        // A chat is a request an older Mac cannot decode, so it is sent only to a Mac that said it can. See ``AgentChatSupport``.
        hostSupportsAgentChat = AgentChatSupport.maySend(toHostDeclared: hello.supportsAgentChat)
        hostSupportsClipboardImages = ClipboardImages.maySend(toHostDeclared: hello.supportsClipboardImages)
        // Compositing is the first request this client can make that an older Mac cannot decode at all. See ``MosaicSupport``.
        hostSupportsMosaic = MosaicSupport.maySend(hostDeclared: hello.supportsMosaic)
        hostSupportsSourceThumbnails = SourceThumbnailSupport.maySend(
            hostDeclared: hello.supportsSourceThumbnails
        )
        hostSupportsDeviceOrientation = DeviceOrientationSupport.maySend(
            hostDeclared: hello.supportsDeviceOrientation
        )
        hostSupportsVirtualDisplayManagement = VirtualDisplayManagementSupport.maySend(
            hostDeclared: hello.supportsVirtualDisplayManagement
        )
        hostPushesTerminalAlertsWhileConnected = hello.pushesTerminalAlertsWhileConnected == true
        hostSupportsFileBrowser = hello.supportsFileBrowser == true
        hostSupportsAgentModelPicker = hello.supportsAgentModelPicker == true
        hostSupportsAgentPermissionModes = hello.supportsAgentPermissionModes == true
        hostSupportsAgentUsage = hello.supportsAgentUsage == true
        hostSupportsAgentSessionImport = hello.supportsAgentSessionImport == true
        hostSupportsAgentPause = hello.supportsAgentPause == true
        hostChatAgents = Set(hello.agentChatAgents ?? ["claude", "codex"])
        UserDefaults.standard.set(hello.serverID, forKey: SessionModel.lastHostIDKey)
        // Also the name the widget and Lock Screen card show, as the only one that came from the Mac itself; a first pairing by ID knows no name until this arrives.
        UserDefaults.standard.set(HostRecordLimits.clippedName(hello.hostName), forKey: SessionModel.lastHostNameKey)
        SharedStore.lastHostName = HostRecordLimits.clippedName(hello.hostName)
        let hostName = HostRecordLimits.clippedName(hello.hostName)
        if model.hostNames[hello.serverID] != hostName {
            model.hostNames[hello.serverID] = hostName
            model.hostNames = HostRecordLimits.pruned(model.hostNames, keeping: Set(model.pairedHostIDs))
            UserDefaults.standard.set(model.hostNames, forKey: SessionModel.hostNamesKey)
            model.publishKnownMacs()
        }
        if let macs = hello.macAddresses, !macs.isEmpty {
            model.hostMACAddresses[hello.serverID] = HostRecordLimits.clippedMACAddresses(macs)
            model.hostMACAddresses = HostRecordLimits.pruned(model.hostMACAddresses, keeping: Set(model.pairedHostIDs))
            if let data = try? JSONEncoder().encode(model.hostMACAddresses) {
                UserDefaults.standard.set(data, forKey: "hostMACAddresses")
            }
        }
    }

    func apply(catalog: CaptureCatalog) {
        self.catalog = catalog
        // A changed catalogue may have lost a window (an app quit, a stale arrangement, a tile stopped). The reaction is not immediate: see ``scheduleMosaicGapCheck()``.
        if !mosaicChoices.isEmpty { model.scheduleMosaicGapCheck() }
        // Consumed here, the first catalogue this connection receives, before the branch below decides between a session with nothing chosen and one repeating a choice the Mac forgot. See ``pendingSourceReassertion``.
        let reasserting = pendingSourceReassertion
        pendingSourceReassertion = false
        if let requested = sourceRequestedOnOpen,
           let descriptor = catalog.all.first(where: { $0.id == requested }) {
            // A notification named this window, which outranks anything remembered.
            sourceRequestedOnOpen = nil
            model.selectSource(descriptor)
        } else if activeSourceID == nil {
            // A remembered arrangement comes back before the default: the fallback picks the first display, and a mosaic asked on top would be a second capture. Only when nothing has been chosen yet; a session already showing something keeps it, and a resumed one still has the mosaic's id as its source.
            let remembered = model.mosaicToRestore(hostID: hostID, catalog: catalog)
            if !remembered.isEmpty {
                // Asked for, not remembered: the store holds the arrangement, thinned here by what this catalogue can see, and writing the thinned version back would lose a window the catalogue merely failed to list.
                model.showMosaic(remembered, remembering: false)
            } else if let source = model.sourceToRestore(hostID: hostID, catalog: catalog) {
                // After the arrangement, before the first display. Through the door rather than assigned here: a remembered source is one the Mac has to be told about, else the session would describe a picture the Mac is not sending.
                model.selectSource(source)
            } else if let first = catalog.displays.first ?? catalog.all.first {
                // Asked for too, though it is the Mac's fallback: the Mac waits a second for an ask, which a new pairing would otherwise always spend.
                model.selectSource(first)
            }
        } else if reasserting {
            // A reconnect where this end knows what it wants: told again, since the fresh capture pipeline has no memory of `activeSourceID`. See ``pendingSourceReassertion``.
            // Read from `activeSourceID`, not `isAskingForMosaic`: the session object is new and only `activeSourceID` and `mosaicChoices` were carried (see ``SessionModel/connect(to:replacing:)``).
            // Matched by prefix, not by recomputing the layout hash: the `stableID` hashes the exact canvas size, which depends on window sizes a re-enumerated catalogue may report in a different order or precision, so a hash comparison never matched and the reassertion silently did nothing. The prefix is the part of the id that does not move. See ``CaptureSource/stableID``.
            if !mosaicChoices.isEmpty, activeSourceID?.hasPrefix("mosaic:") == true {
                model.showMosaic(mosaicChoices, remembering: false)
            } else if let activeSourceID,
                      let descriptor = catalog.all.first(where: { $0.id == activeSourceID }) {
                model.selectSource(descriptor.source)
            }
        }
    }

    func applyRelayQuotaExceeded() {
        model.relayRemainingSecondsFromRelay = RelayRemainingReport(seconds: 0, receivedAt: Date())
        // Through ``StoreManager/access``, the answer every other screen states: `relayPlan` is what the device tells the relay and is free with no receipt (a developer override, or before StoreKit answers), so read for copy it contradicted every badge.
        let plan = model.storeManager.access.plan
        if plan?.isUnlimited != false {
            // A plan the relay does not meter was refused, so the relay read this device as free (an older relay or an unknown plan). Nothing to do here and a retry against an updated relay may succeed, so it stays a note rather than a paywall in front of someone who has paid.
            append(note: String(localized: "Relay quota reached. Your subscription is active; please try again later."))
        } else if model.relaySessionDropped {
            // The mid-session cut: the relay ends a session the moment its allowance is spent by dropping the connection, with no way to say why (everything past the token is TLS). This sheet says it, opening on the plans. Not the paywall itself, whose question is which plan is worth it; being sold to while being told is how a wall turns into a con.
            model.spentAllowance = plan ?? .free
            Analytics.relayAllowanceExhausted(path: connectionPath?.rawValue)
            model.relaySessionDropped = false
            // The cut is simultaneous: the relay reads one counter per client, so every spliced session is dropped at once. Ending only the Mac that noticed leaves dead tabs behind the sheet.
            // The flag is cleared above so the ends this causes cannot re-enter this branch.
            // Nothing is recorded here about who ended it: `disconnect(deliberate: false)` assigns that flag from its own argument, so an earlier write was overwritten before it could be read. The ladder arming after a cut is long-standing: the next attempt is refused for the same reason and answered by the branch below.
            model.disconnect(deliberate: false, endReason: .quota)
        } else if model.spentAllowance != nil {
            // A later refusal from the same ladder has nothing to add: the explanation is on screen and the purchase screen must not cover it. The ladder re-arms on a failed attempt by design, so this is the second and third refusal of the same cut.
            userEndedDeliberately = true
            model.stopReconnecting()
        } else if hasBeenReady {
            // An automatic retry of a session that was working: explained by the sheet and never sold at, since the user did not walk into this.
            model.spentAllowance = plan ?? .free
            Analytics.relayAllowanceExhausted(path: connectionPath?.rawValue)
            reportEnd(.quota)
            userEndedDeliberately = true
            model.stopReconnecting()
        } else {
            // Free with the day's allowance spent and the user tapped Connect into it: a wall they walked into, not a session taken away, which is why this branch is the paywall.
            model.paywallReason = .quotaExhausted
            Analytics.relayAllowanceExhausted(path: nil)
            // Suppress the reconnect ladder: there is nothing to reconnect to.
            userEndedDeliberately = true
            model.stopReconnecting()
        }
    }
}
