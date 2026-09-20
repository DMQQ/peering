import MacCastKit
import RemoteCore
import SSHCore
import SwiftUI
import UIKit

/// The app's five places, in the order the bar shows them.
///
/// A whole file's business rather than the picker's alone, which is why it sits outside it: the bar
/// draws itself from this list, and a nested type would be private to the picker. It is still
/// `private`, so the list of the app's screens does not leave this file.
///
/// The bar reads its titles and glyphs from here rather than from a second list beside it, so the
/// two cannot come apart: a sixth screen means a sixth case, and the switch in
/// ``HostPickerView/content(for:)`` does not compile until that case has somewhere to go.
private enum Screen: CaseIterable, Identifiable {
    case connect, servers, sessions, faq, settings

    var id: Self { self }

    var title: String {
        switch self {
        case .connect: "Connect"
        case .servers: "Servers"
        case .sessions: "Sessions"
        case .faq: "FAQ"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .connect: "macbook.and.iphone"
        case .servers: "server.rack"
        case .sessions: "clock.fill"
        case .faq: "questionmark.circle.fill"
        case .settings: "gearshape.fill"
        }
    }
}

/// Root navigation for connection, sessions, help, and settings.
struct HostPickerView: View {
    @Binding var acknowledgedFailure: String?

    @Environment(SSHModel.self) private var servers
    @State private var screen: Screen = .connect

    var body: some View {
        TabView(selection: $screen) {
            ForEach(Screen.allCases) { item in
                content(for: item)
                    // The bar goes while a shell is up, and it is asked for on the screen rather
                    // than on the tab view: applied there the bar is made invisible but is not
                    // taken away, and its five items stay in the accessibility tree over the
                    // shell. The condition belongs to the Servers tab, because the shell screen
                    // is that tab's own root and nothing about the hierarchy changes when it
                    // opens.
                    .toolbar(
                        item == .servers && servers.selectedTerminal != nil ? .hidden : .visible,
                        for: .tabBar
                    )
                    .tabItem { Label(item.title, systemImage: item.symbol) }
                    .tag(item)
            }
        }
        .tint(ColorPalette.accent)
        .preferredColorScheme(.dark)
        // `initial: true`, because "open a shell on prod" usually launches the app rather than
        // arriving at one already open, so the flag is already up by the time this view first
        // appears and a plain `onChange` would sit there waiting for it to change.
        .onChange(of: servers.wantsFocus, initial: true) { _, wantsFocus in
            guard wantsFocus else { return }
            screen = .servers
            // Cleared, or the tab would jump back here every time the user tried to leave it.
            servers.wantsFocus = false
        }
    }

    /// The screen behind each tab.
    ///
    /// One switch rather than five copies inlined into the tab view, so the five places the app
    /// has are stated once. The bar's own titles and glyphs come from ``Screen``, which the tab
    /// view reads directly.
    @ViewBuilder
    private func content(for item: Screen) -> some View {
        switch item {
        case .connect: HomeTab(acknowledgedFailure: $acknowledgedFailure)
        case .servers: SSHTab()
        case .sessions: ActivityTab()
        case .faq: NavigationStack { FAQView() }
        case .settings: SettingsTab()
        }
    }
}

private extension View {
    /// A card arriving on the Connect screen, late enough after the one above it to be seen
    /// arriving.
    ///
    /// The delay is the whole point of it. All six cards are in place on the first frame
    /// otherwise, and a screen that is simply *there* when the header finishes moving reads as a
    /// screen that was always there — the eye takes the header as the only thing that happened.
    /// Each card coming up a twentieth of a second after the one above it is what makes the
    /// arrival read downward, in the order the screen wants to be read.
    func connectEntrance(visible: Bool, delay: Double, reduceMotion: Bool) -> some View {
        opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : 14)
            .animation(
                reduceMotion
                    ? nil
                    : Motion.arrive.delay(delay),
                value: visible
            )
    }
}

/// The Connect screen's own numbers: the margin its content keeps, and the two sizes the header
/// opens and rests at.
///
/// The sizes are here rather than written into the modifier that happens to use each one, because
/// they are a single decision — the header opens at one set and ends at the other — and six
/// constants scattered through a body is six chances for one of them to be left behind at a size
/// nothing else agrees with.
private enum Hero {
    /// Named because the header measures its centring against the width that is left after the
    /// content's inset, so the number is needed in two places and has to be the same one.
    static let inset: CGFloat = 18
    /// Where the mark sits below the top of the header once it has arrived.
    static let topGap: CGFloat = 12
    /// The header's height at rest. It is fixed, and the hero is an offset from it.
    static let height: CGFloat = 202

    static let openMark: CGFloat = 136
    static let restMark: CGFloat = 72
    static let openName: CGFloat = 82
    static let restName: CGFloat = 60
    static let openTracking: CGFloat = -3.2
    static let restTracking: CGFloat = -2.2
    static let openGap: CGFloat = 26
    static let restGap: CGFloat = 16
}

// MARK: - Home Tab

private struct HomeTab: View {
    @Environment(SessionModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsManualConnection = false
    @State private var showsRemotePairing = false
    /// The header's arrival, in four numbers: how far the mark has appeared, how far the name has
    /// followed it, and how far the pair has travelled left and up. Two of them are separate
    /// because they are separate curves — see ``Motion/travel``.
    @State private var markZoom: CGFloat = 0
    @State private var titleReveal: CGFloat = 0
    @State private var heroTravel: CGFloat = 0
    @State private var heroRise: CGFloat = 0
    /// The name's and the tagline's widths, measured once while the hero is standing still in the
    /// middle of the screen — the only moment either is the width the centring wants. See
    /// ``header(viewport:)``.
    @State private var nameWidth: CGFloat = 0
    @State private var taglineWidth: CGFloat = 0
    @State private var sectionsVisible = false
    @State private var entranceStarted = false
    @State private var forgetTarget: String?
    @State private var renameTarget: String?
    @State private var renameDraft = ""

    @Binding var acknowledgedFailure: String?

    @AppStorage(PreferenceKeys.hasSeenWelcome) private var hasSeenWelcome = true
    @AppStorage(PreferenceKeys.requireBiometricUnlock) private var requiresBiometricUnlock = false

    /// How often the Connect tab asks the relay which paired Macs are up.
    ///
    /// Twenty seconds, which is a compromise the screen does not have to make but the relay does:
    /// the answer only changes when a Mac starts or stops, which is a user-scale event, and a
    /// phone that asked every second would be a phone telling the relay where its owner is at a
    /// constant rate for a fact that has not changed.
    private static let presenceInterval: Duration = .seconds(20)

    private var showsUnacknowledgedFailure: Bool {
        guard let message = model.failureMessage else { return false }
        return message != acknowledgedFailure
    }

    private var failurePresentation: FailurePresentation {
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
                    title: "Update this iPhone's app",
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

    var body: some View {
        @Bindable var model = model
        return NavigationStack {
            ZStack {
                AppBackdrop()

                GeometryReader { geometry in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            header(viewport: geometry.size)

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

                            identityFooter
                                .connectEntrance(
                                    visible: sectionsVisible,
                                    delay: 0.24,
                                    reduceMotion: reduceMotion
                                )
                        }
                        .padding(.horizontal, Hero.inset)
                        .padding(.bottom, 36)
                    }
                    .scrollDisabled(!sectionsVisible)
                }
                .onAppear(perform: runEntrance)
            }
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
                Text("The new name is only used on this iPhone. The Mac keeps its own name.")
            }
        }
    }

    // MARK: Header

    /// The mark, the name, and the two devices the name is about.
    ///
    /// The mark is the hero and the drawing of the devices is the footnote, which is the reverse of
    /// how this was built and is the whole of why the screen now opens on something worth looking
    /// at. The mark used to be a badge beside the wordmark, at 62 points, which is small enough
    /// that a solid pear and an outlined one stop being a mark and become a grey tile with
    /// something unreadable in it. It carries a display size perfectly well; the drawing of the two
    /// devices does not — at the top of the screen it was geometry, and what it means only arrives
    /// when the dots between them are moving, which is the one thing a large still frame cannot do.
    ///
    /// So they trade places. The mark is bare rather than in a tile, because a rounded square with
    /// a picture inside it is what an app icon looks like in a place that is *listing* apps, and the
    /// devices sit under the tagline where an illustration belongs — small enough to read as a
    /// diagram of what the sentence above it says, and animated, which is now the point of them
    /// rather than a detail nobody was looking at.
    ///
    /// The arrival is written as one journey in four numbers — how far the mark has appeared, how
    /// far the name has, and how far the pair has travelled left and up — rather than the four
    /// booleans it used to be, which is the difference between an animation and a set of states
    /// that happen to be switched at intervals. The distinction is not academic: three of the five
    /// things this header changes on the way to its corner were *layout* — the stack's alignment,
    /// the frame's alignment, and the font — and layout is not interpolated. The mark glided to the
    /// corner on a frame that was being resized a point at a time while the name beside it jumped,
    /// twice, and the pair of them crossed the middle of the screen on the way. Everything that
    /// moves here now moves through a number.
    ///
    /// The centring is measured rather than laid out, and that is the price of the rest of it.
    /// `alignment` is the free way to put a mark in the middle of a screen, and it is free because
    /// it is a decision the layout makes afresh each time rather than a value it can travel
    /// through — so the frame that centres the mark is also the frame that snaps it. Two labels are
    /// measured once, while the hero is standing still in the middle of the screen, and from then
    /// on the centring is an offset like every other part of the movement.
    private func header(viewport: CGSize) -> some View {
        // The width the header has to centre against: the viewport's, less the inset the stack
        // this sits in keeps from both edges. Named in that stack's padding and here, which is why
        // it is named at all rather than written as 18 in two places and kept in step by hand.
        let width = max(viewport.width - Hero.inset * 2, 1)

        return VStack(alignment: .leading, spacing: 0) {
            // The frame is larger than the mark looks, and that is the mark's own doing: the
            // artwork carries a margin of its own, so a 72-point frame draws a pear about 52
            // points tall. Sized to what the drawing needs rather than to the number, so the
            // settled mark sits optically level with the wordmark under it.
            //
            // The two devices used to be drawn opposite it, across this row, and they have gone
            // to the connecting card — which is where the thing they draw is actually happening.
            // A header is a name and a promise; the moment a phone and a Mac are reaching for
            // each other is a moment, and it belongs on the screen that is about that moment.
            Image("Pears")
                .resizable()
                .scaledToFit()
                .frame(width: markSize, height: markSize)
                .scaleEffect(markZoom)
                .opacity(markZoom)
                .padding(.bottom, markGap)
                .offset(x: centred(markSize, in: width))
                .accessibilityHidden(true)

            Wordmark(size: nameSize, tracking: nameTracking)
                .opacity(titleReveal)
                .offset(
                    x: centred(nameWidth, in: width),
                    y: 14 * (1 - titleReveal)
                )
                // Measured while it is still, and only while it is. The name is resizing for the
                // whole of the journey to the corner, and a measurement that keeps arriving
                // mid-flight is a number the movement has to keep re-aiming at. What is wanted
                // from it is the width the name has *centred* — the state it is leaving, not the
                // one it is on its way to, whose offset is zero whatever this says.
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measured in
                    guard heroTravel == 0 else { return }
                    nameWidth = measured
                }

            Text("Your Mac, from anywhere.")
                // A text style rather than the point size the name under it travels through, so
                // this one line still answers to the reader's own text size. It is the copy here
                // and the name is the sign, and only one of those is allowed to be a picture.
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
                .opacity(titleReveal)
                .offset(
                    x: centred(taglineWidth, in: width),
                    y: 10 * (1 - titleReveal)
                )
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measured in
                    guard heroTravel == 0 else { return }
                    taglineWidth = measured
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The resting height, and only ever the resting height. It used to grow to fill the screen
        // while the header was centred, which is how the header was centred — the frame grew, the
        // stack centred itself inside it, and the height was pulled back to 202 at the fold. That
        // is the second thing that made the fold jump: both ends of it were layout. The frame is
        // now the header's own height whatever the hero is doing, and the hero's position in the
        // screen is an offset of its own.
        //
        // Shorter than it was when the devices were drawn under the type: what is left in the
        // header is a mark, two lines and a tagline, and the height that used to hold an
        // illustration below them would now be a gap above the first card.
        .frame(height: Hero.height, alignment: .topLeading)
        .padding(.top, Hero.topGap)
        // Down to the middle of the screen and back. Taken off the mark's middle rather than the
        // block's, because the mark is all there is to look at for the first half second of the
        // screen, and a pair of elements centred on their own middle puts the mark above the middle
        // of the screen — which is exactly where the name that has not arrived yet is going to go.
        .offset(y: (viewport.height / 2 - Hero.topGap - markSize / 2) * (1 - heroRise))
    }

    /// How far something has to move to sit in the middle of the header's width, less the part of
    /// that journey the hero has already made.
    private func centred(_ size: CGFloat, in width: CGFloat) -> CGFloat {
        (width - size) / 2 * (1 - heroTravel)
    }

    /// The mark's size, which the header opens at and keeps its own half of the journey through.
    private var markSize: CGFloat {
        Hero.restMark + (Hero.openMark - Hero.restMark) * (1 - heroTravel)
    }

    /// The gap under it, which closes as it sits down.
    private var markGap: CGFloat {
        Hero.restGap + (Hero.openGap - Hero.restGap) * (1 - heroTravel)
    }

    private var nameSize: CGFloat {
        Hero.restName + (Hero.openName - Hero.restName) * (1 - heroTravel)
    }

    private var nameTracking: CGFloat {
        Hero.restTracking + (Hero.openTracking - Hero.restTracking) * (1 - heroTravel)
    }

    private func runEntrance() {
        guard !entranceStarted else { return }
        entranceStarted = true
        guard !reduceMotion else {
            markZoom = 1
            titleReveal = 1
            heroTravel = 1
            heroRise = 1
            sectionsVisible = true
            return
        }

        // Four beats rather than one animation: the mark, then the name, then the header taking
        // its place at the top of the screen, then the cards. Each is a thing arriving, and a thing
        // that arrives at the same moment as three others has not been seen arriving at all.
        //
        // Every one of them is `Motion.arrive` — critically damped, so nothing here overshoots.
        // The header travels a long way, and a spring with give in it would run past where it was
        // going and come back with six cards animating underneath it, which is the bounce this
        // screen used to have.
        //
        // The third beat is the one with two curves in it. The leftward travel and the upward one
        // are told to start at the same moment and are given different shapes, and the mark takes
        // the path between them — which is a curve, because two curves that disagree at every
        // point but the last are how a curve is made out of two straight ones.
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            withAnimation(Motion.arrive) { markZoom = 1 }

            try? await Task.sleep(for: .milliseconds(520))
            withAnimation(Motion.arrive) { titleReveal = 1 }

            try? await Task.sleep(for: .milliseconds(600))
            withAnimation(Motion.travel) { heroTravel = 1 }
            withAnimation(Motion.rise) { heroRise = 1 }

            try? await Task.sleep(for: .milliseconds(620))
            withAnimation(Motion.arrive) { sectionsVisible = true }
        }
    }

    // MARK: Cards

    private var connectionFailureCard: some View {
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
    private var connectionsSection: some View {
        VStack(spacing: 0) {
            nearbyCardContent
                .padding(16)
            Divider()
                .overlay(Color.white.opacity(0.1))
            remotePairingEntry
                .padding(16)
            Divider()
                .overlay(Color.white.opacity(0.1))
            pairedCardContent
                .padding(16)
        }
        .cardBackground()
    }

    private var nearbyCardContent: some View {
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

            if model.hosts.isEmpty {
                Text(model.browseStatus)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
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
                            title: host.name,
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
                    }
                }
                Text(model.browseStatus).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The way in for a Mac that discovery cannot produce and never will.
    ///
    /// Its own section rather than another row under Nearby, because the two are mutually
    /// exclusive answers: Nearby is where the Mac is on this network, and this is for when it
    /// is not on any network this phone can see. It sits between Nearby and the stored Macs
    /// for the same reason: it is the second thing to try, and the Macs already paired are the
    /// answer once both of those have not produced one.
    private var remotePairingEntry: some View {
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
                        // leads. It is also the room the badge lands in when the plan is out of
                        // Macs.
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
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

    private var pairedCardContent: some View {
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

    private var firstPairingCard: some View {
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

    private var securityCard: some View {
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

    private var identityFooter: some View {
        VStack(spacing: 8) {
            Text(model.thisDeviceDescription)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)

            Text("No account, nothing stored. Direct on your own network, relayed only when your Mac is somewhere else.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // MARK: Rows

    private func pairedRow(_ hostID: String) -> some View {
        let reach = model.reachability(ofHost: hostID)
        let isActive = model.currentHostID == hostID && model.phase == .ready
        return HStack(spacing: 10) {
            // **The second Mac is the paid one.** Drawn as itself with its own dot and its own
            // name, dimmed, with the plan's name at its trailing edge rather than a padlock in
            // the row's place: a row is how somebody finds out the app can hold more than one
            // Mac open at all, and the first Mac is free on every plan, which is why
            // `isIncluded` is passed rather than left to the map. See ``PlanLocked``.
            PlanLocked(
                capability: .concurrentSessions,
                title: "Another Mac",
                placement: .trailing,
                diameter: 44,
                isIncluded: model.canAddAnotherSession
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
            .disabled(model.isBusy)
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
    private func pairedRowDetail(
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
            return reach == .nearby ? "Connected via LAN" : "Connected via Relay"
        }
        switch reach {
        case .nearby: return "Nearby · tap to connect"
        case .viaRelay: return "Online · tap to connect"
        case .notRegistered:
            guard let last = model.lastConnectedAt[hostID] else { return "Not reachable" }
            return "Not reachable · last used "
                + RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date())
        case .unknown:
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
    private func wakeRefusalReason(hostID: String, reach: SessionModel.Reachability) -> String? {
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
    private var canPairAnotherMac: Bool {
        model.storeManager.access.includes(.extraMacs) || model.pairedHostIDs.isEmpty
    }

    private func hostRow(_ host: DiscoveredHost) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: "macbook")

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
    private func identityFailureCard(_ failure: String) -> some View {
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

    private func manualSheet(address: Binding<String>, port: Binding<String>) -> some View {
        NavigationStack {
            VStack(spacing: 16) {
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
                .tint(ColorPalette.ink)
                .foregroundStyle(.black)
                .disabled(model.isBusy || model.manualAddress.isEmpty)
            }
            .padding(24)
            .frame(maxHeight: .infinity, alignment: .top)
            .navigationTitle("Connect by Address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { showsManualConnection = false }
                }
            }
        }
        .presentationDetents([.height(220)])
        .preferredColorScheme(.dark)
    }

    /// Kept as a name here rather than replaced at three call sites, but it is now the shared
    /// one — the Servers tab draws the same heading, and two copies of a shape that appears on two
    /// screens is how they drift apart.
    private func sectionLabel(_ title: String, systemImage: String) -> some View {
        Controls.sectionLabel(title, systemImage: systemImage)
    }

    /// The number after `marker` in a message like "host speaks v13, client speaks v12".
    ///
    /// Written as a fetch rather than a regex because the sentence is ours: the relay builds it,
    /// this app reads it, and the two live in one repository. If the phrasing ever changes, the
    /// parse returns nil and the failure falls back to blaming the Mac — which is the old
    /// behaviour, and no worse than it was.
    private static func version(in message: String, after marker: String) -> Int? {
        guard let start = message.range(of: marker) else { return nil }
        let digits = message[start.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    private func isCompatible(_ host: DiscoveredHost) -> Bool {
        guard let version = host.protocolVersion else { return true }
        return version == ProtocolInfo.version
    }
}

// MARK: - Activity Tab

/// One line in "Recent connections", whichever kind of machine was at the other end.
///
/// A type of this screen's own rather than a protocol over the two records. They answer different
/// questions — a Mac session has a path and a byte count, a shell has an outcome — and the only
/// things this list needs from either are a name, a sentence and a time. Flattening them here
/// keeps that pairing in one place instead of teaching two stored records about a list neither of
/// them is part of.
private enum RecentConnection: Identifiable {
    case mac(ClientSessionRecord)
    case shell(SSHConnectionRecord)

    var id: UUID {
        switch self {
        case .mac(let session): return session.id
        case .shell(let record): return record.id
        }
    }

    var startedAt: Date {
        switch self {
        case .mac(let session): return session.startedAt
        case .shell(let record): return record.startedAt
        }
    }
}

private struct ActivityTab: View {
    @Environment(SessionModel.self) private var model
    /// Read only for the shells: this tab is where everything that has connected is listed, and a
    /// shell is one of those — see ``recent``.
    @Environment(SSHModel.self) private var servers

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackdrop()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        TabScreenHeader(
                            "Sessions",
                            detail: "Recent sessions and relay use."
                        )
                        relayCard
                        recentConnectionsCard
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                    .padding(.bottom, 36)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // MARK: Relay card

    private var relayCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Controls.sectionLabel("Relay", systemImage: "network")
                Spacer()
                // The plan's own name rather than a generic badge. It used to say PRO for anyone
                // who had bought anything, which became wrong the moment there was more than one
                // paid tier: a subscriber who bought Relay would have been told they were on Pro,
                // and the two do not meter the same.
                if let tier = model.storeManager.activeTier {
                    Text(tier.name.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.8)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.blue.opacity(0.25), in: Capsule())
                        .foregroundStyle(.blue)
                }
            }
            .foregroundStyle(.secondary)

            if model.storeManager.relayPlan.isUnlimited {
                HStack(spacing: 12) {
                    Image(systemName: "infinity")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.blue)
                        .frame(width: 42, height: 42)
                        .background {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.blue.opacity(0.12))
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Unlimited relay")
                            .font(.subheadline.weight(.semibold))
                        Text("Your subscription removes the daily cap.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                // The whole allowance becomes the way to buy more of it. This card is where the
                // limit is felt — it is the one place in the app that counts the minutes down — so
                // it is the one place where "and here is how to stop counting" belongs. The
                // chevron is what says so: every other row in the app that pushes somewhere has
                // one, and a card that opens something without looking like it does is a card
                // nobody taps.
                //
                // Drawn for a Relay subscriber as well as for a free user, because Relay has an
                // allowance rather than no limit: the plan that is metered is the plan that needs a
                // meter, and the one it is metered against is read from the plan rather than
                // assumed to be free's.
                Button(action: openUpgradePaywall) {
                    relayMeterDetail
                        .contentShape(Rectangle())
                }
                .buttonStyle(RailButtonStyle(scale: 0.99))
            }
        }
        .cardSurface()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var relayMeterDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(model.storeManager.relayPlan == .free ? "Free relay time" : "Daily relay time")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(relayRemainingLabel)
                    .font(.caption.weight(.medium))
                    // Warms with the bar rather than staying grey. The figure is the one piece of
                    // text on this card that changes on its own, and the moment it stops being
                    // comfortable it should be the thing the eye lands on.
                    .foregroundStyle(relayAllowanceIsLow ? ColorPalette.caution : .secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(relayAllowanceIsLow ? ColorPalette.caution : ColorPalette.accent)
                        .frame(
                            width: geo.size.width * (model.relayAllowanceRemainingFraction ?? 0),
                            height: 6
                        )
                        .animation(.easeInOut(duration: 0.6), value: model.relayAllowanceRemainingFraction)
                }
            }
            .frame(height: 6)

            HStack {
                Label(relayBandwidth, systemImage: "arrow.down.circle")
                Spacer()
                // The window the meter is counting in, which is the relay's own: a rolling 24
                // hours rather than a calendar day. It used to say "last 30 days", which was the
                // history limit and never what this number was.
                Text("last 24 hours")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text("Your allowance is measured in relay time, not a fixed number of sessions. What is shown here is estimated from the sessions recorded on this iPhone.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if relayAllowanceIsLow {
                upgradeCallToAction
                    .padding(.top, 2)
            }
        }
    }

    /// The way to buy more of the allowance, drawn only when there is little enough left to say so.
    ///
    /// The card is already a button and already carries a chevron, which is enough for somebody who
    /// came here to read the figure. This is for the moment the figure has become the reason they
    /// came: there, "tap the card" is something the user has to work out, and a filled control they
    /// can simply press is not.
    ///
    /// A label rather than a `Button`, and deliberately — it is *inside* one. The whole card is the
    /// control, so every point of this is already part of a target that was there before it; a real
    /// button nested in a button's label is a second tap target inside the first, and the outer one
    /// is the one that wins.
    private var upgradeCallToAction: some View {
        HStack(spacing: 7) {
            Text("Upgrade to \(recommendedTierName)")
            Image(systemName: "arrow.right")
                .font(.caption.weight(.bold))
        }
        .font(.subheadline.weight(.bold))
        .foregroundStyle(ColorPalette.onInk)
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(ColorPalette.ink, in: Capsule())
    }

    /// Whether the day's allowance is nearly gone — the only thing the bar says beyond its length.
    ///
    /// One state rather than two, and the threshold is the same constant the app's own offer is
    /// decided on, so the card and the sheet that follows a session agree about what "running low"
    /// means. A bar at zero is the extreme of a bar running out, and two ambers a few degrees apart
    /// — one for nearly, one for gone — is the near-match the palette's own note warns about. The
    /// words distinguish the two; the colour only says to look.
    ///
    /// `nil` is an unmetered plan, which draws no bar at all — the unlimited branch is above.
    private var relayAllowanceIsLow: Bool {
        guard let fraction = model.relayAllowanceRemainingFraction else { return false }
        return fraction <= SessionOfferPolicy.lowRelayAllowanceFraction
    }

    /// Opens the paywall saying the thing that is true of this card right now.
    ///
    /// The two reasons are not interchangeable: one names the figure that is left, the other
    /// describes what the relay is to somebody who has not been told. A card showing "41m left" that
    /// opens a screen never mentioning the 41 minutes is a card that was not reading its own meter —
    /// and the same two reasons are what ``SessionModel`` chooses between when it offers by itself,
    /// so the figure means the same thing whichever way the screen was reached.
    private func openUpgradePaywall() {
        if relayAllowanceIsLow, let remaining = model.relaySecondsRemainingEstimate {
            model.paywallReason = remaining <= 0 ? .quotaExhausted : .runningLow(remaining: remaining)
        } else {
            model.paywallReason = .upgrade
        }
    }

    /// The name on the card's button when there is little enough left to offer more.
    ///
    /// Read off the tier the app recommends rather than typed, because the paywall this opens will
    /// have that tier already chosen — and a button that names one rung of a ladder while the screen
    /// it opens points at another is a promise the next tap breaks.
    private var recommendedTierName: String {
        StoreManager.Tier.allCases.first { $0.isRecommended }?.name ?? "Pro"
    }


    // MARK: Recent connections

    private var recentConnectionsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Controls.sectionLabel("Recent connections", systemImage: "clock.arrow.circlepath")

            if recent.isEmpty {
                Text("Nothing yet. Pair with a Mac, or add a server in the Servers tab, and what you connect to appears here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 8) {
                    ForEach(recent) { item in
                        recentItemRow(item)
                    }
                }
            }
        }
        .cardSurface()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Everything that has connected lately, Mac and server alike, newest first.
    ///
    /// One list rather than two cards, because the question the card answers — "what have I been
    /// connected to" — does not change with the kind of machine at the other end. A shell on a VPS
    /// is a connection this phone made in exactly the way a session with a Mac is, and two lists
    /// would make the reader merge them by timestamp themselves.
    private var recent: [RecentConnection] {
        let macs = model.sessionHistory.map(RecentConnection.mac)
        let shells = servers.history.map(RecentConnection.shell)
        return (macs + shells).sorted { $0.startedAt > $1.startedAt }
    }

    @ViewBuilder
    private func recentItemRow(_ item: RecentConnection) -> some View {
        switch item {
        case .mac(let session):
            NavigationLink {
                SessionHistoryDetail(session: session)
            } label: {
                recentRow(
                    symbol: "macbook",
                    name: session.hostName,
                    detail: "\(session.path.rawValue) · \(durationLabel(session.duration)) · \(bytesLabel(session.videoBytesReceived))",
                    startedAt: session.startedAt,
                    // The one of the three that leads somewhere: this is a NavigationLink, so the
                    // chevron is a promise the row keeps.
                    navigates: true
                )
            }
            .buttonStyle(.plain)

        case .shell(let record):
            // Only when the server is still there. A log entry that outlives the machine is the
            // reason the record carries its own copy of the name — but a *tap* on one has nowhere
            // to go, and offering it would be a row that fails by opening a screen for a server
            // that does not exist. Same rule as the Servers list, which draws nothing it cannot
            // open.
            if let host = servers.hosts.first(where: { $0.id == record.hostID }) {
                Button { servers.requestOpen(host) } label: {
                    recentRow(
                        symbol: "server.rack",
                        name: record.name,
                        detail: shellDetail(record),
                        startedAt: record.startedAt
                    )
                }
                .buttonStyle(.plain)
            } else {
                recentRow(
                    symbol: "server.rack",
                    name: record.name,
                    detail: shellDetail(record),
                    startedAt: record.startedAt
                )
            }
        }
    }

    /// What happened, in the order a reader wants it: how it went, then what it cost in time.
    ///
    /// A failure leads with the *reason* instead, because for a connection that never opened the
    /// duration is how long it took to fail — a number nobody has ever wanted — and the sentence
    /// the server produced is the only thing on the row worth reading.
    private func shellDetail(_ record: SSHConnectionRecord) -> String {
        if let reason = record.outcome.reason {
            return "Failed · \(reason)"
        }
        return "\(durationLabel(record.duration)) · Connected"
    }

    /// One line of a session. Not always a row that leads anywhere, which is the whole of why it
    /// takes a parameter for the chevron.
    ///
    /// **This one row is three different things.** A Mac session pushes to its detail; a server
    /// shell is *opened*, which is an action rather than a destination; and a server that has since
    /// been removed does nothing at all and is not even a button. Drawn with a chevron
    /// unconditionally, it promised "there is somewhere further on" on all three, and kept that
    /// promise on one. A chevron is a claim about what a tap does, so it is decided by what the tap
    /// does rather than by which list the row is in.
    private func recentRow(
        symbol: String,
        name: String,
        detail: String,
        startedAt: Date,
        navigates: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 4) {
                Text(RelativeDateTimeFormatter().localizedString(for: startedAt, relativeTo: Date()))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if navigates {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .rowSurface()
    }

    /// How much relay is left, in the shape ``RelayTime`` decides on.
    ///
    /// The arithmetic moved there when the paywall needed the same sentence: the two screens are
    /// read within seconds of each other — the meter, then the sheet it opens — and a figure spelled
    /// two ways between them is the sort of difference that makes an app look like it is guessing.
    ///
    /// `nil` means the plan is not metered, which this card does not draw a meter for — the
    /// unlimited branch is above. The word is here so the label is total rather than a crash waiting
    /// for a plan change to arrive while the card is on screen.
    private var relayRemainingLabel: String {
        guard let remaining = model.relaySecondsRemainingEstimate else { return "Unlimited" }
        return RelayTime.label(remaining) + " left"
    }

    private var relayBandwidth: String {
        ByteCountFormatter.string(fromByteCount: model.relayVideoBytesThisPeriod, countStyle: .file)
            + " received"
    }

    private func bytesLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func durationLabel(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}

/// One past connection, in full.
///
/// Written as cards on the app's own backdrop rather than as a `List`, which is what it was: a
/// system list brings its own background, its own section headers, its own insets and its own
/// everything, and inside a screen that is all near-black and outlined cards it read as a piece of
/// iOS that had landed on top of the app. The rows here are the same rows the Sessions tab uses
/// for the connection it is in — a label on the left, a value on the right — so a session you had
/// and a session you are having are recognisably the same kind of thing.
private struct SessionHistoryDetail: View {
    let session: ClientSessionRecord

    /// Whether the last copy landed, so the button can say so for a moment.
    ///
    /// The same shape the Settings screen uses for its diagnostics copy, and for the same
    /// reason: a button that gives no feedback after a tap reads as a button that did nothing,
    /// and the only way to check a paste is to go somewhere else and paste it.
    @State private var copied = false

    var body: some View {
        ZStack {
            AppBackdrop()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Controls.card("Connection") {
                        detailRow("Mac", session.hostName)
                        Controls.divider
                        detailRow("Path", session.path.rawValue)
                        Controls.divider
                        detailRow("Started", session.startedAt.formatted(date: .abbreviated, time: .shortened))
                        Controls.divider
                        detailRow("Duration", durationLabel)
                        Controls.divider
                        detailRow(
                            "Video received",
                            ByteCountFormatter.string(fromByteCount: session.videoBytesReceived, countStyle: .file)
                        )
                    }

                    Controls.card("Session log") {
                        if session.logs.isEmpty {
                            Text("No diagnostic events were recorded for this session.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(session.logs.enumerated()), id: \.offset) { _, entry in
                                    Text(entry)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 36)
            }
        }
        .navigationTitle(session.hostName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // In the bar rather than in the card, because the card scrolls: a control that
            // belongs to the whole screen should not be somewhere you have to scroll to find,
            // and a session with sixty log lines puts the bottom of the card a long way down.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = logText
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .accessibilityLabel(copied ? "Copied" : "Copy session log")
            }
        }
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(ColorPalette.backdrop, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    /// Everything this screen knows, as text, for pasting into a message.
    ///
    /// The rows and the log together rather than the log alone. A line saying which transport
    /// carried the picture means nothing without the session it belongs to, and whoever reads
    /// this is looking at a pasted paragraph with none of the context this screen has around
    /// it. The version is here for the same reason: "the two apps must match" is the first
    /// thing anybody asks about a failure, and it costs one line to answer it in advance.
    private var logText: String {
        var lines = [
            "Peering session · \(session.hostName)",
            "App version: \(ProtocolInfo.version)",
            "Path: \(session.path.rawValue)",
            "Started: \(session.startedAt.formatted(date: .abbreviated, time: .shortened))",
            "Duration: \(durationLabel)",
            "Video received: \(ByteCountFormatter.string(fromByteCount: session.videoBytesReceived, countStyle: .file))",
            "",
        ]
        lines += session.logs.isEmpty
            ? ["No diagnostic events were recorded for this session."]
            : session.logs
        return lines.joined(separator: "\n")
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .font(.subheadline)
    }

    private var durationLabel: String {
        let seconds = Int(session.duration.rounded())
        return seconds < 60 ? "\(seconds) seconds" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

// MARK: - Settings Tab

private struct SettingsTab: View {
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
                            detail: "Defaults for this iPhone and every session."
                        )
                        deviceSection
                        controlsSection
                        qualitySection
                        remoteAccessSection
                        securitySection
                        pipSection
                        homeScreenWidgetSection
                        liveActivitySection
                        if !model.pairedHostIDs.isEmpty { trustedMacsSection }
                        identitySection
                        moreSection
                    }
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
            Controls.row("Device name", systemImage: "iphone") {
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
                    .onChange(of: pipAutoStart) { _, on in SessionPiP.shared.autoStart = on }
            }

            if model.storeManager.access.includes(.pictureInPicture) {
                Controls.divider

                Controls.row("Try it now", systemImage: "pip.enter") {
                    Button("Start") { SessionPiP.shared.start() }
                        .font(.subheadline.weight(.medium))
                        .disabled(!SessionPiP.isSupported || !model.phase.holdsSession)
                }

                if let attempt = SessionPiP.shared.lastAttempt {
                    Controls.divider
                    Controls.row("Last attempt", systemImage: "clock.arrow.circlepath") {
                        Text(attempt)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let refusal = SessionPiP.shared.lastRefusal {
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
    private var identitySection: some View {
        Controls.card(
            "Device identity",
            footer: "How Macs recognise this iPhone. Created once, on first launch."
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

// MARK: - Supporting types

private struct FailurePresentation {
    let title: String
    let message: String
    let isRelayFailure: Bool
}

// MARK: - The site

/// Where the other half of the product comes from.
///
/// **The Mac app is not in the App Store.** It is a download, and that makes this the only address
/// that reaches it: the phone app cannot find a Mac that has nothing running on it, cannot pair
/// with one, and shows an empty list until that download is installed and opened. So the two rows
/// that carry this link are not marketing in a settings screen, they are the two places somebody
/// is stuck without it.
///
/// Named once here for the reason ``Legal`` is named once in `PaywallView`: the address has to
/// agree with the site, the App Store listing and the docs, and only one of those can be compiled.
enum PeeringSite {
    /// The download page rather than the home page: it is one tap further from a visitor who has
    /// not decided and one tap closer to the file for somebody who has.
    static let download = URL(string: "https://getpeering.app/download")!
}


