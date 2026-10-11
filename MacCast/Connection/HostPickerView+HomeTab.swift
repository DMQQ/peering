import MacCastKit
import RemoteCore
import SSHCore
import SwiftUI
import UIKit


// MARK: - Home Tab

struct HomeTab: View {
    @Environment(SessionModel.self) var model
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @State var showsManualConnection = false
    @State var showsRemotePairing = false
    @State var markZoom: CGFloat = 0
    @State var titleReveal: CGFloat = 0
    @State var heroTravel: CGFloat = 0
    @State var heroRise: CGFloat = 0
    @State var nameWidth: CGFloat = 0
    @State var taglineWidth: CGFloat = 0
    @State var sectionsVisible = false
    @State var entranceStarted = false
    /// Whether the entrance has played this launch: the tab is rebuilt on return from a session, and the animation is for opening the app.
    static var entranceHasPlayed = false
    @State var forgetTarget: String?
    @State var renameTarget: String?
    @State var renameDraft = ""

    @Binding var acknowledgedFailure: String?

    @AppStorage(PreferenceKeys.hasSeenWelcome) private var hasSeenWelcome = true
    @AppStorage(PreferenceKeys.requireBiometricUnlock) var requiresBiometricUnlock = false
    @AppStorage(PreferenceKeys.hasSeenTourConnect) var hasSeenTourConnect = false

    private var contentMaxWidth: CGFloat {
        horizontalSizeClass == .regular ? AdaptiveLayout.wideContentMaxWidth : AdaptiveLayout.contentMaxWidth
    }

    /// Twenty seconds: the answer only changes when a Mac starts or stops.
    private static let presenceInterval: Duration = .seconds(20)

    var body: some View {
        @Bindable var model = model
        return NavigationStack {
            ZStack {
                AppBackdrop()

                GeometryReader { geometry in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            // Capped as `.adaptiveContentColumn()` caps the column: on an iPad `geometry` is the full detail pane, and centring against that pushed the header's opening position off to one side.
                            header(viewport: CGSize(
                                width: min(geometry.size.width, contentMaxWidth),
                                height: geometry.size.height
                            ))

                            if showsUnacknowledgedFailure {
                                connectionFailureCard
                                    .connectEntrance(
                                        visible: sectionsVisible,
                                        delay: 0,
                                        reduceMotion: reduceMotion
                                    )
                            }

                            if let failure = model.identityFailure {
                                identityFailureCard(failure)
                                    .connectEntrance(
                                        visible: sectionsVisible,
                                        delay: 0.04,
                                        reduceMotion: reduceMotion
                                    )
                            }

                            resumeCard
                                .connectEntrance(
                                    visible: sectionsVisible,
                                    delay: 0.06,
                                    reduceMotion: reduceMotion
                                )

                            if model.pairedHostIDs.isEmpty {
                                firstPairingCard
                                    .connectEntrance(
                                        visible: sectionsVisible,
                                        delay: 0.08,
                                        reduceMotion: reduceMotion
                                    )
                                    .tourAnchor(.connectFirstPairing)
                            }

                            connectionsSection
                                .connectEntrance(
                                    visible: sectionsVisible,
                                    delay: 0.12,
                                    reduceMotion: reduceMotion
                                )
                            securityCard
                                .connectEntrance(
                                    visible: sectionsVisible,
                                    delay: 0.18,
                                    reduceMotion: reduceMotion
                                )
                        }
                        .adaptiveContentColumn()
                        .padding(.horizontal, Hero.inset)
                        .padding(.bottom, 36)
                    }
                    .scrollDisabled(!sectionsVisible)
                }
                .onAppear(perform: runEntrance)
            }
            // On the stack but inside the NavigationStack: the steps' frames are read from cards in this stack, and a preference does not travel out through a navigation container.
            .firstRunTours(dueConnectTours) { $0.markSeen() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            // Polled from the tab, not the model: `.task` is cancelled when the view goes away, so the relay is asked only while the answer is on screen.
            .task {
                while !Task.isCancelled {
                    await model.refreshRelayPresence()
                    try? await Task.sleep(for: Self.presenceInterval)
                }
            }
            .sheet(isPresented: $showsManualConnection) {
                manualSheet(address: $model.manualAddress, port: $model.manualPort)
            }
            .sheet(isPresented: $showsRemotePairing) {
                RemotePairingSheet()
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
                Text("The new name is only used on this device. The Mac keeps its own name.")
            }
        }
    }

}
