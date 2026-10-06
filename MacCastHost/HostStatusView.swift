import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import MacCastKit
import RemoteCore
import SwiftUI

enum HostSection: String, CaseIterable, Identifiable {
    case overview
    case devices
    case sessions
    case activity
    case privacy
    case settings
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return String(localized: "Overview")
        case .devices: return String(localized: "Devices")
        case .sessions: return String(localized: "Sessions")
        case .activity: return String(localized: "Activity")
        case .privacy: return String(localized: "Privacy")
        case .settings: return "Settings"
        case .about: return String(localized: "About")
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "rectangle.connected.to.line.below"
        case .devices: return "iphone.and.arrow.forward"
        case .sessions: return "clock.arrow.circlepath"
        case .activity: return "waveform.path"
        case .privacy: return "lock.shield"
        case .settings: return "gearshape"
        case .about: return "info.circle"
        }
    }
}

struct HostStatusView: View {
    @Environment(HostModel.self) var model
    @Environment(Updater.self) var updater
    @State var section: HostSection

    init(initialSection: HostSection = .overview) {
        _section = State(initialValue: initialSection)
    }

    /// Held by the view: the task is cancelled with it, which stops a hidden window screenshotting the Mac every couple of seconds.
    @State var preview: CGImage?

    /// A draft: the model setter restarts the listener, so binding directly would restart the server on every keystroke. Committed on Return or focus loss, and reverted if not a usable port.
    @State var portDraft = ""
    @FocusState var portFocused: Bool
    @State var forgetDevice: (id: String, name: String)?
    @State var hoveredDeviceID: String?
    @State var hoveredSection: HostSection?
    @State var heroHovered = false

    /// Off, the snapshot loop does not run at all: the preview is the only thing this app does that touches the screen unasked. Not a privacy control; a connected iPhone sees the same screen either way.
    @AppStorage("hostShowsPreview") var showsPreview = true
    @AppStorage(PreferenceKeys.analyticsEnabled) var analyticsEnabled = true

    private struct PreviewKey: Equatable {
        let source: CaptureSource?
        let enabled: Bool
    }

    @State var paneWidth: CGFloat = 0

    /// Named because the picture height is computed from the width this leaves.
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
                        // Above the pane: a pairing request is the only thing needing an answer, and burying it leaves a phone waiting on nobody.
                        if model.pairing != nil || model.lastOutcome != nil {
                            pairingSection
                        }

                        pane
                    }
                    .padding(.horizontal, Self.paneInset)
                    .padding(.top, 22)
                    .padding(.bottom, 28)
                    // The pane is only as wide as its widest row and a scroll view centres it, so pin leading.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Only the width is kept: the height is derived from it, so feeding it back would make the layout solve itself.
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                        if abs(width - paneWidth) > 1 { paneWidth = width }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // The sidebar and titlebar default to a material over the window background; filling behind the split view and pinning the toolbar leaves nothing drawing its own grey.
        .background(HostPalette.backdrop)
        .toolbarBackground(HostPalette.backdrop, for: .windowToolbar)
        // Ink, not the accent: a window-wide tint paints every system button blue, including destructive ones, and drowns the one blue that means something.
        .tint(HostPalette.controlTint)
        // The ideal is load-bearing: windowResizability(.contentSize) sizes the window to what content asks for, and a minimum alone gave a 900 wide window despite defaultSize 1200.
        .frame(minWidth: 900, idealWidth: 1200, minHeight: 620, idealHeight: 870)
        .task { model.start() }
        // Keyed on the source so a switch refreshes at once, and on the switch so turning the preview off cancels the loop (the only way to stop taking screenshots).
        .task(id: PreviewKey(source: model.capturingSource, enabled: showsPreview)) {
            // capturingSource is the gate: with no device there is no coordinator and snapshot() answers nil, and writing that nil every two seconds invalidated the whole window.
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
        // A statement and two actions, not a question: a yes/no title made the right answer the button that did the opposite. Let it sleep is the default because a wrong answer costs one reconnect.
        .alert(
            "This Mac is being kept awake and nothing is connected",
            isPresented: Binding(
                get: { model.asksToReleaseKeepAwake },
                set: { if !$0 { model.asksToReleaseKeepAwake = false } }
            )
        ) {
            Button("Let it sleep") {
                Task { await model.releaseKeepAwakeNow() }
            }
            .keyboardShortcut(.defaultAction)

            Button("Keep it awake") { model.asksToReleaseKeepAwake = false }
        } message: {
            Text("Sleeping is the one you forget, so it is the default. Let it sleep and this Mac goes back to sleeping on its own; the switches in Settings stay exactly where you left them, and connecting again puts it all back. Keep it awake and nothing changes.")
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
            // The picture and how to get here only; devices and the log have their own panes.
            VStack(alignment: .leading, spacing: 24) {
                nowShowingSection
                connectSection
            }
        case .devices:
            devicesSection
        case .sessions:
            sessionsSection
        case .activity:
            activitySection
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

    /// Connected outranks listening: Ready for iPhone is true whether or not a client is attached.
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
            return others > 0 ? String(localized: "Connected: \(client.name) +\(others)") : String(localized: "Connected: \(client.name)")
        }
        switch model.status {
        case .idle: return String(localized: "Not hosting")
        case .starting: return "Starting…"
        case .listening: return "Waiting for a device"
        case .failed(let message): return String(localized: "Error: \(message)")
        }
    }

    /// The oldest client is the session.
    var connectedClient: ConnectedClient? {
        model.connectedClients.min { $0.since < $1.since }
    }

    func formatted(_ code: String) -> String { formattedPairingCode(code) }

    func qrCode(encoding payload: String) -> NSImage? { qrCodeImage(encoding: payload) }
}

/// Without pixel dimensions: the stream size follows the source, which the phone chooses, so a number would be wrong for every other source.
extension CaptureResolution {
    var title: String {
        switch self {
        case .full: return String(localized: "Full")
        case .threeQuarters: return "3/4"
        case .half: return String(localized: "Half")
        }
    }
}

extension CaptureFrameRate {
    var title: String {
        switch self {
        case .thirty: return String(localized: "30 fps")
        case .sixty: return String(localized: "60 fps")
        case .oneTwenty: return String(localized: "120 fps")
        }
    }
}

extension View {
    /// Lifted further than a panel because it is the only thing that needs an answer; an accent ring read as a promotional banner.
    func priorityPanel() -> some View {
        padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HostPalette.raised, in: RoundedRectangle(cornerRadius: HostPalette.panelRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: HostPalette.panelRadius, style: .continuous)
                    .strokeBorder(HostPalette.hairline, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.4), radius: 20, y: 9)
    }
}

#Preview {
    HostStatusView()
        .environment(HostModel())
        .environment(Updater())
}
