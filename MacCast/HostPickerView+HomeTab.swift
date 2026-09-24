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
    /// The header's arrival, in four numbers: how far the mark has appeared, how far the name has
    /// followed it, and how far the pair has travelled left and up. Two of them are separate
    /// because they are separate curves — see ``Motion/travel``.
    @State var markZoom: CGFloat = 0
    @State var titleReveal: CGFloat = 0
    @State var heroTravel: CGFloat = 0
    @State var heroRise: CGFloat = 0
    /// The name's and the tagline's widths, measured once while the hero is standing still in the
    /// middle of the screen — the only moment either is the width the centring wants. See
    /// ``header(viewport:)``.
    @State var nameWidth: CGFloat = 0
    @State var taglineWidth: CGFloat = 0
    @State var sectionsVisible = false
    @State var entranceStarted = false
    @State var forgetTarget: String?
    @State var renameTarget: String?
    @State var renameDraft = ""

    @Binding var acknowledgedFailure: String?

    @AppStorage(PreferenceKeys.hasSeenWelcome) private var hasSeenWelcome = true
    @AppStorage(PreferenceKeys.requireBiometricUnlock) var requiresBiometricUnlock = false
    /// Whether this screen's first-run tips have been seen. See ``Tour``.
    @AppStorage(PreferenceKeys.hasSeenTourConnect) var hasSeenTourConnect = false

    /// The column the header actually renders in, whatever ``adaptiveContentColumn()`` below caps
    /// it to for this width class. Read here rather than restated, so the two cannot drift apart
    /// — see ``body``.
    private var contentMaxWidth: CGFloat {
        horizontalSizeClass == .regular ? AdaptiveLayout.wideContentMaxWidth : AdaptiveLayout.contentMaxWidth
    }

    /// How often the Connect tab asks the relay which paired Macs are up.
    ///
    /// Twenty seconds, which is a compromise the screen does not have to make but the relay does:
    /// the answer only changes when a Mac starts or stops, which is a user-scale event, and a
    /// phone that asked every second would be a phone telling the relay where its owner is at a
    /// constant rate for a fact that has not changed.
    private static let presenceInterval: Duration = .seconds(20)

    var body: some View {
        @Bindable var model = model
        return NavigationStack {
            ZStack {
                AppBackdrop()

                GeometryReader { geometry in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            // Capped the same way `.adaptiveContentColumn()` below caps the
                            // column the header actually renders in. `geometry` is this
                            // `GeometryReader`'s own size, which on an iPad's regular-width
                            // layout is the full detail pane — wider than the capped, centred
                            // column the mark and name are laid out in. Centring the header's
                            // opening position against the wider, uncapped number pushed it off
                            // to one side instead of the middle of the column it actually opens
                            // in.
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
            // On the stack rather than in it, so the tips cover the screen including the backdrop,
            // and inside the `NavigationStack` rather than outside it: the frames the steps are
            // drawn around are read from the cards in this stack, and a preference does not travel
            // out through a navigation container.
            .firstRunTours(dueConnectTours) { $0.markSeen() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            // **Polled from the tab, not from the model**, so the asking stops the moment this
            // screen is not the one being looked at. `.task` is cancelled when the view goes away,
            // which is the whole of the lifetime rule: the relay is asked which Macs this phone
            // cares about only while the answer is on screen.
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
