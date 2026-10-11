import RemoteCore
import SwiftUI

/// Everything between the tour and a first picture as one screen that moves down its own list: install, open, choose a Mac, enter the code, approve. The Mac appears in step three the moment it is found, and the code and the approval happen in the same column rather than on another screen.
struct FirstConnectionScreen: View {
    /// True for the beat after the Mac approves, before the picture: every step shows done and the heading says so.
    var isConnected = false
    var onSkip: () -> Void

    @Environment(SessionModel.self) private var model
    @State private var addressCopied = false
    @State private var submitted: PairingSubmission?
    @State private var showsManualConnection = false
    @State private var showsScanner = false
    @State private var scanNote: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = false
    /// How many of the first two steps have been ticked. The Mac being visible on the network is what proves both, so they are ticked one after the other when it appears: all at once, they read as steps that were never asked.
    @State private var ticked = 0

    private var found: [DiscoveredHost] { model.hosts }
    private var hostName: String { model.shownHostName ?? String(localized: "your Mac") }

    private enum Stage { case choosing, connecting, code(String), approving, connected }

    private var stage: Stage {
        if isConnected { return .connected }
        switch model.phase {
        case .connecting, .handshaking: return .connecting
        case .confirming(let code): return submitted == nil ? .code(code) : .approving
        default: return .choosing
        }
    }

    var body: some View {
        ZStack {
            ColorPalette.backdrop.ignoresSafeArea()
            TopGlow()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(isConnected ? "Paired with “\(hostName)”" : "Connect your first Mac")
                            .font(DisplayFont.display(32))
                            .tracking(-1)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.opacity)
                        Text(isConnected
                             ? "Opening your Mac…"
                             : "Peering needs a small app running on your Mac. It takes a minute, and you only do it once.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .appearing(arrived, index: 0, reduceMotion: reduceMotion)
                    steps
                }
                .padding(.horizontal, 22)
                .padding(.top, 48)
                .padding(.bottom, 24)
                .frame(maxWidth: 460, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { footer }
        }
        .preferredColorScheme(.dark)
        .animation(Motion.settle, value: model.phase)
        .animation(Motion.settle, value: submitted == nil)
        .task {
            model.startBrowsing()
            try? await Task.sleep(for: .milliseconds(60))
            arrived = true
        }
        .task(id: found.isEmpty) { await tick(found: !found.isEmpty) }
        .sensoryFeedback(.selection, trigger: ticked)
        .onChange(of: model.phase) { _, phase in
            if case .confirming = phase {} else { submitted = nil }
        }
        .sheet(isPresented: $showsManualConnection) { ManualConnectionSheet() }
        .sheet(isPresented: $showsScanner) { scanner }
    }

    // MARK: - Steps

    private var steps: some View {
        let shownTicked = isIdle ? ticked : 2
        return VStack(alignment: .leading, spacing: 0) {
            GuideStepRow(number: 1, state: shownTicked >= 1 ? .done : .current, title: String(localized: "Install Peering on your Mac")) {
                if shownTicked < 1 { installLink }
            }
            .appearing(arrived, index: 1, reduceMotion: reduceMotion)
            GuideStepRow(number: 2, state: shownTicked >= 2 ? .done : .current, title: String(localized: "Open it, on the same Wi-Fi")) {
                if shownTicked < 2 { Text("Keep the Mac awake and on the network this iPhone is on.").stepDetail() }
            }
            .appearing(arrived, index: 2, reduceMotion: reduceMotion)
            GuideStepRow(number: 3, state: chooseState, title: String(localized: "Choose your Mac")) { chooseContent }
                .appearing(arrived, index: 3, reduceMotion: reduceMotion)
            GuideStepRow(number: 4, state: codeState, title: String(localized: "Enter the code")) { codeContent }
                .appearing(arrived, index: 4, reduceMotion: reduceMotion)
            GuideStepRow(number: 5, state: approveState, title: approveTitle, isLast: true) {
                if let submitted { PairingApproveDetail(kind: submitted, hostName: hostName) }
            }
            .appearing(arrived, index: 5, reduceMotion: reduceMotion)
        }
        .animation(reduceMotion ? nil : Motion.settle, value: ticked)
    }

    private func tick(found: Bool) async {
        guard found else { return ticked = 0 }
        // Waits out the entrance first, so the ticks are seen being made.
        try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 700))
        guard !Task.isCancelled else { return }
        ticked = 1
        try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 450))
        guard !Task.isCancelled else { return }
        ticked = 2
    }

    private var chooseState: GuideStepState {
        switch stage {
        case .choosing: return ticked >= 2 ? .current : .pending
        case .connecting: return .current
        case .code, .approving, .connected: return .done
        }
    }

    private var codeState: GuideStepState {
        switch stage {
        case .code: return .current
        case .approving, .connected: return .done
        case .choosing, .connecting: return .pending
        }
    }

    private var approveState: GuideStepState {
        switch stage {
        case .approving: return .current
        case .connected: return .done
        default: return .pending
        }
    }

    private var approveTitle: String {
        submitted == .scanned ? String(localized: "Securing the pairing") : String(localized: "Approve on your Mac")
    }

    @ViewBuilder
    private var chooseContent: some View {
        switch stage {
        case .choosing:
            VStack(alignment: .leading, spacing: 10) {
                if model.localNetworkDenied {
                    LocalNetworkNotice()
                } else if found.isEmpty || ticked < 2 {
                    HStack(spacing: 10) {
                        ProgressView().tint(ColorPalette.ink)
                        Text("Looking for your Mac…").stepDetail()
                    }
                } else {
                    macList.transition(.opacity.combined(with: .offset(y: 8)))
                }
                if case .failed(let message) = model.phase {
                    Text(message).font(.caption).foregroundStyle(ColorPalette.danger).fixedSize(horizontal: false, vertical: true)
                }
                alternatives
            }
        case .connecting:
            HStack(spacing: 10) {
                ProgressView().tint(ColorPalette.ink)
                Text("Connecting to “\(hostName)”…").stepDetail()
            }
        case .code, .approving, .connected:
            Text("Connected to “\(hostName)”. It is showing six digits.").stepDetail()
        }
    }

    @ViewBuilder
    private var codeContent: some View {
        switch stage {
        case .code(let code): PairingCodeEntry(code: code, hostName: hostName, submitted: $submitted)
        case .approving, .connected: Text("Code entered.").stepDetail()
        case .choosing, .connecting: EmptyView()
        }
    }

    // MARK: - Pieces

    /// The camera is the sheet's whole content, so it is running the moment the sheet is up. A Mac's own QR carries its ID, which is all this step needs: the Mac then asks for the code like any other.
    private var scanner: some View {
        NavigationStack {
            PairingCodeScanner { payload in
                guard let hostID = try? PairingPayload.hostID(from: payload) else {
                    scanNote = String(localized: "That is not a Mac's code. Scan the QR code in the sidebar of the Peering app on your Mac.")
                    return false
                }
                scanNote = nil
                showsScanner = false
                model.openHostLink(hostID: hostID)
                return true
            }
            .overlay(alignment: .bottom) {
                if let scanNote {
                    Text(scanNote)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.horizontal, 24)
                        .padding(.bottom, 28)
                }
            }
            .ignoresSafeArea()
            .navigationTitle("Scan your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .sheetToolbar(onCancel: { showsScanner = false })
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var footer: some View {
        if !isConnected { footerButton }
    }

    private var footerButton: some View {
        Button(isIdle ? "I'll do this later" : "Cancel pairing") {
            guard !isIdle else { return onSkip() }
            if case .confirming = model.phase {
                model.confirmPairing(accepted: false)
            } else {
                model.disconnect()
            }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.bottom, 8)
    }

    private var isIdle: Bool { if case .choosing = stage { return true } else { return false } }

    private var alternatives: some View {
        HStack(spacing: 8) {
            alternative(String(localized: "Scan QR code"), systemImage: "qrcode.viewfinder") { showsScanner = true }
            alternative(String(localized: "Enter address"), systemImage: "keyboard") { showsManualConnection = true }
        }
    }

    private func alternative(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.footnote.weight(.medium))
                .foregroundStyle(ColorPalette.ink)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(RailButtonStyle(scale: 0.97))
        .rowSurface()
    }

    private var installLink: some View {
        HStack(spacing: 4) {
            Link(destination: PeeringSite.download) {
                HStack {
                    Text("getpeering.app/download")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ColorPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                }
                .padding(.leading, 14)
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .tint(ColorPalette.ink)
            Button {
                UIPasteboard.general.string = "getpeering.app/download"
                addressCopied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    addressCopied = false
                }
            } label: {
                Image(systemName: addressCopied ? "checkmark" : "doc.on.doc")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(addressCopied ? ColorPalette.ink : .secondary)
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(addressCopied ? "Address copied" : "Copy the download address")
        }
        .rowSurface()
    }

    private var macList: some View {
        VStack(spacing: 8) {
            ForEach(found) { host in
                Button {
                    model.connect(to: .discovered(host))
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "macbook").font(.title3).foregroundStyle(ColorPalette.ink)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(host.name).font(.subheadline.weight(.semibold)).foregroundStyle(ColorPalette.ink)
                            Text("Tap to connect").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RailButtonStyle(scale: 0.98))
                .rowSurface()
            }
        }
    }
}

private extension View {
    /// Each piece rises into place a beat after the one above it.
    func appearing(_ arrived: Bool, index: Int, reduceMotion: Bool) -> some View {
        opacity(arrived ? 1 : 0)
            .offset(y: arrived || reduceMotion ? 0 : 16)
            .animation(reduceMotion ? nil : Motion.arrive.delay(0.06 * Double(index)), value: arrived)
    }
}
