import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import RemoteCore
import SwiftUI

/// The host's window: whether it is reachable, whether it has permission to do its job,
/// and the pairing code when a client is asking to be trusted.
/// What the window is showing.
///
/// A sidebar rather than one long scroll, because the window has grown two kinds of content
/// that want different things: what is happening *now* — the picture, who is attached — and
/// what can be configured or looked up, which is reference material that gets in the way until
/// it is wanted. `overview` is first and is the default, so the answer to "is someone on my
/// Mac" costs nothing.
enum HostSection: String, CaseIterable, Identifiable {
    case overview
    case sessions
    case privacy
    case settings
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .sessions: return "Sessions"
        case .privacy: return "Privacy"
        case .settings: return "Settings"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "rectangle.connected.to.line.below"
        case .sessions: return "clock.arrow.circlepath"
        case .privacy: return "lock.shield"
        case .settings: return "gearshape"
        case .about: return "info.circle"
        }
    }
}

struct HostStatusView: View {
    @Environment(HostModel.self) var model
    @State var section: HostSection = .overview

    /// The last still of what the connected device is seeing.
    ///
    /// Held by the view rather than the model because it is only wanted while this window is
    /// on screen — the task below is cancelled with the view, which is what stops a closed or
    /// hidden window taking a screenshot of this Mac every couple of seconds.
    @State var preview: CGImage?

    /// What is in the port field while it is being edited.
    ///
    /// A draft rather than a binding to the model, because the model's setter restarts the
    /// listener: bound directly, every keystroke would tear down the server and start it again.
    /// The value is committed on Return or when the field loses focus, and reverted if it is not
    /// a usable port — a field that silently keeps a number the host is not listening on is worse
    /// than one that puts the real number back.
    @State var portDraft = ""
    @FocusState var portFocused: Bool
    @State var forgetDevice: (id: String, name: String)?
    @State var hoveredDeviceID: String?
    @State var hoveredSection: HostSection?
    @State var heroHovered = false

    /// Whether this window keeps a still of the Mac on screen behind it.
    ///
    /// Persisted, because it is a decision about the Mac rather than about the moment. Off, the
    /// snapshot loop does not run at all — see the `.task` in `body` — which is the point: the
    /// preview is the only thing this app does that touches the screen when nobody asked it to.
    /// It is not a privacy control and does not pretend to be one — a connected iPhone sees the
    /// same screen either way. It is for a window left open on a second display, a screen being
    /// shared, or simply not wanting the Mac photographed every two seconds for a picture nobody
    /// is looking at.
    @AppStorage("hostShowsPreview") var showsPreview = true

    /// What the snapshot loop is keyed on: which source, and whether a preview is wanted at all.
    private struct PreviewKey: Equatable {
        let source: CaptureSource?
        let enabled: Bool
    }

    /// How much room the pane has, measured rather than assumed.
    ///
    /// The picture's height is derived from it — see `previewHeight` — so the frame it is drawn
    /// in is always the shape of what is being sent rather than a strip with letterbox bars
    /// above and below it.
    @State var paneWidth: CGFloat = 0

    /// What this app is costing the Mac, and the timer that keeps it current.
    ///
    /// Held by the window rather than by the card, and that is the whole arrangement: the card
    /// is rebuilt every time its section is opened, while the readings' baseline has to survive
    /// as long as there is something to subtract from. `Resources` in
    /// `HostStatusView+Resources.swift` is where it is fed.

    /// The pane's own inset from the window edge.
    ///
    /// Named because the picture's height is computed from the width this leaves: a number in two
    /// places is a picture that stops fitting the frame it is drawn in.
    static let paneInset: CGFloat = 26

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
        } detail: {
            ZStack {
                HostPalette.backdrop.ignoresSafeArea()
                HostPalette.stageLight.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        // Above the pane rather than inside one. A pairing request is the only
                        // thing in this window that needs an answer, and burying it in a
                        // section the user is not looking at is how a phone sits at "waiting
                        // for you to compare the digits" with nobody comparing them.
                        if model.pairing != nil || model.lastOutcome != nil {
                            pairingSection
                        }

                        pane
                    }
                    .padding(.horizontal, Self.paneInset)
                    .padding(.top, 22)
                    .padding(.bottom, 28)
                    // The pane is only as wide as its widest row, and a scroll view centres
                    // what it is given. Overview looked right by accident — the preview pane
                    // asks for the full width — while a pane holding one short line of text
                    // floated in the middle of the window.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Measured rather than assumed, and only the width is kept: the picture's
                    // height follows from it, so feeding the height back in would be asking the
                    // layout to solve itself. The width does not depend on the height, so this
                    // settles on the first pass and only moves when the window does.
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                        if abs(width - paneWidth) > 1 { paneWidth = width }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // The sidebar column and the titlebar are two more surfaces the system paints for us, and
        // both default to a material over the window's own background — which on this window is
        // the grey the palette exists to get away from. Filling the window with the stage behind
        // the split view and pinning the toolbar to it leaves nothing drawing its own grey.
        .background(HostPalette.backdrop)
        .toolbarBackground(HostPalette.backdrop, for: .windowToolbar)
        // Ink, not the accent, and the difference is the whole reason this window reads as one
        // object rather than as a settings panel: a window-wide accent tint paints every button
        // the system draws for us, so `Forget all` and `Copy all` and two segmented pickers all
        // arrive blue, and the one blue that is supposed to mean something is somewhere in that
        // crowd. Left monochrome, the accent is spent on exactly two things — the row you are on
        // and the button that starts sharing — and both are things you look for.
        //
        // It is also what fixes a destructive button drawing in the colour that means "press me".
        .tint(HostPalette.controlTint)
        // The floor a Mac window for this job should never go under, and the size it wants to be.
        // The pane is only ever as wide as its widest row, so a window narrowed past the floor
        // starts clipping sentences rather than reflowing them.
        //
        // The ideal is load-bearing rather than decorative: `windowResizability(.contentSize)`
        // sizes the window to what its content asks for, and a content that only states a minimum
        // gets the minimum — which is how this opened at 900 wide with `defaultSize` set to 1200.
        // `defaultSize` is the first frame a window is ever given; the ideal is what it keeps
        // coming back to.
        .frame(minWidth: 900, idealWidth: 1200, minHeight: 620, idealHeight: 870)
        .task { model.start() }
        // Keyed on the source, so a client switching to another screen refreshes the picture at
        // once instead of showing the old one until the next tick. Two seconds is chosen against
        // what the picture is for: it is here to answer "what can they see", and a still that is
        // a second old answers that as well as a live one, for a fraction of the work.
        //
        // The switch is part of the key as well as a guard, because turning the preview off has
        // to *stop* this loop rather than let it run on drawing pictures nobody asked for. A
        // cancelled task is the only way to stop taking screenshots of someone's Mac.
        .task(id: PreviewKey(source: model.capturingSource, enabled: showsPreview)) {
            // Two reasons to stop, and the second one used to be missing. With no device attached
            // there is no coordinator, so `snapshot()` answers nil in the same breath it is asked
            // — and the loop wrote that nil into `preview` every two seconds regardless, a write
            // that invalidates this window and everything in it. The task is on the window rather
            // than on the Overview pane, so a Mac with nobody on it paid twice a second, on every
            // pane, for a picture it already knew was absent.
            //
            // `capturingSource` is the honest gate rather than a second look at the setting: it
            // is what the pane draws, it is set from the coordinator's own report of what it is
            // sending, and it is nil exactly when there is nothing being sent.
            guard showsPreview, model.capturingSource != nil else {
                preview = nil
                return
            }
            while !Task.isCancelled {
                let shot = await model.snapshot()
                guard !Task.isCancelled else { return }
                preview = shot
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .confirmationDialog(
            "Forget \(forgetDevice?.name ?? "this iPhone")?",
            isPresented: Binding(
                get: { forgetDevice != nil },
                set: { if !$0 { forgetDevice = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Forget", role: .destructive) {
                guard let target = forgetDevice else { return }
                model.unpair(clientID: target.id)
                forgetDevice = nil
            }
            Button("Cancel", role: .cancel) { forgetDevice = nil }
        } message: {
            Text("This phone will be disconnected and must pair again before it can control this Mac.")
        }
    }

    // MARK: - Status

    // MARK: - Sidebar

    @ViewBuilder
    var pane: some View {
        switch section {
        case .overview:
            // The picture first, then how to get here, then the record. The picture is what the
            // window is for and it is also the thing that is *happening* — a Mac with a phone on
            // it should open onto the session, not onto instructions for starting one. The hints
            // sit directly under it, which is where someone who is looking for them will look
            // once they have seen the top of the window, and they withdraw on their own the
            // moment a device attaches — see `connectSection`.
            VStack(alignment: .leading, spacing: 24) {
                nowShowingSection
                connectSection
                overviewLowerDeck
            }
        case .sessions:
            sessionsSection
        case .privacy:
            VStack(alignment: .leading, spacing: 24) {
                permissionsSection
                privacyNote
            }
        case .settings:
            settingsSection
        case .about:
            aboutSection
        }
    }

    // MARK: - Connect

    func sectionHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(HostDisplayFont.display(17))
                .tracking(-0.2)
            Text(detail).font(.caption).foregroundStyle(HostPalette.muted)
        }
    }

    // MARK: - Helpers

    /// Connected outranks listening: "is anyone there" is the question this window is answering,
    /// and "Ready for iPhone" is true whether or not a client is attached — which is why it was
    /// the wrong thing to say while one was.
    var statusColor: Color {
        if !model.connectedClients.isEmpty { return HostPalette.success }
        switch model.status {
        case .listening: return HostPalette.accent
        case .starting: return HostPalette.faint
        case .idle: return HostPalette.faint
        case .failed: return HostPalette.danger
        }
    }

    var statusText: String {
        if let client = model.connectedClients.first {
            let others = model.connectedClients.count - 1
            return others > 0 ? "Connected: \(client.name) +\(others)" : "Connected: \(client.name)"
        }
        switch model.status {
        case .idle: return "Not hosting"
        case .starting: return "Starting…"
        case .listening: return "Waiting for a device"
        case .failed(let message): return "Error: \(message)"
        }
    }

    /// The longest-attached device, or nil when none is.
    ///
    /// With more than one client attached the oldest is the session — it is the one that has
    /// been waiting to be noticed for longest.
    var connectedClient: ConnectedClient? {
        model.connectedClients.min { $0.since < $1.since }
    }

    /// Grouped as `123 456`. Six unbroken digits are harder to compare by eye.
    func formatted(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let middle = code.index(code.startIndex, offsetBy: 3)
        return "\(code[code.startIndex..<middle]) \(code[middle...])"
    }

    /// Draws whatever ``PairingPayload`` encoded, so the strings on this side and the ones the
    /// iPhone parses are produced by one implementation rather than two that agree by hand.
    func qrCode(encoding payload: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: 9, y: 9)) else {
            return nil
        }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

/// The two sizes and the two rates as words.
///
/// Deliberately without the pixel dimensions: the size a stream is built at follows the
/// source, and the source is the phone's to choose — a label carrying numbers would be
/// wrong for every source but the one that happened to be selected when the window was
/// drawn, and the row is on screen while the client switches between them.
extension CaptureResolution {
    var title: String {
        switch self {
        case .full: return "Full"
        case .threeQuarters: return "3/4"
        case .half: return "Half"
        }
    }
}

extension CaptureFrameRate {
    var title: String {
        switch self {
        case .thirty: return "30 fps"
        case .sixty: return "60 fps"
        case .oneTwenty: return "120 fps"
        }
    }
}

extension View {
    /// The pairing card, and the one place in the window that is allowed to raise its voice.
    ///
    /// A pairing request is the only thing here that needs an answer from the person at the Mac,
    /// so it lifts off the stage further than a panel does and takes the accent into its edge —
    /// the whole card, rather than a coloured bar down one side of it.
    func priorityPanel() -> some View {
        padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HostPalette.raised, in: RoundedRectangle(cornerRadius: HostPalette.panelRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: HostPalette.panelRadius, style: .continuous)
                    .strokeBorder(HostPalette.accent.opacity(0.35), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.4), radius: 20, y: 9)
    }
}

#Preview {
    HostStatusView()
        .environment(HostModel())
}
