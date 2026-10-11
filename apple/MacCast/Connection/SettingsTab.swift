import MacCastKit
import MessageUI
import RemoteCore
import SSHCore
import SwiftUI
import UIKit

// MARK: - Settings Tab

struct SettingsTab: View {
    @Environment(SessionModel.self) var model
    @AppStorage(PreferenceKeys.requireBiometricUnlock) var requiresBiometricUnlock = false
    @AppStorage(PreferenceKeys.allowRelay) var allowsRelay = true
    @AppStorage(PreferenceKeys.analyticsEnabled) var analyticsEnabled = true
    @AppStorage(PreferenceKeys.pipAutoStart) var pipAutoStart = true
    @AppStorage(PreferenceKeys.liveActivities) var liveActivitiesEnabled = true
    @AppStorage(PreferenceKeys.hasSeenWelcome) var hasSeenWelcome = true
    @AppStorage(PreferenceKeys.hidesPanelAfterSelect) var hidesPanelAfterSelect = true
    @AppStorage(PreferenceKeys.opensKeyboardForTextFields) var opensKeyboardForTextFields = true
    @AppStorage(PreferenceKeys.interactionMode) var interactionMode: InteractionMode = .control
    @AppStorage(PreferenceKeys.scalesToFill) var scalesToFill = false
    @AppStorage(PreferenceKeys.streamQuality) var streamQuality: SessionModel.StreamQuality = .auto
    @State var deviceNameDraft = ""
    @State var query = ""
    @State var copiedDiagnostics = false
    @State var showingMailComposer = false
    @State var showsRedeemAlert = false
    @State var redeemDraft = ""
    @State var redeemFailure: String?
    @FocusState var deviceNameFocused: Bool
    @Environment(\.openURL) var openURL

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
                        if shows(.remoteAccess) { inviteSection }
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

    /// The reset button is gone on purpose: the relay counts free minutes against the client ID, so a fresh identity handed out a fresh free allowance. Do not put it back.

}

// MARK: - Home Screen Widget Preview
