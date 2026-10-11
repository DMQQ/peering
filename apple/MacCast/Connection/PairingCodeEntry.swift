import RemoteCore
import SwiftUI

enum PairingSubmission { case typed, scanned }

/// The step where the six digits on the Mac are given to the phone, by typing or by scanning. The code is known here, so a wrong one is refused the moment the sixth digit lands and a right one goes straight through.
struct PairingCodeEntry: View {
    @Environment(SessionModel.self) private var model
    let code: String
    let hostName: String
    @Binding var submitted: PairingSubmission?

    @State private var enteredCode = ""
    @State private var isWrong = false
    @State private var shakes: CGFloat = 0
    @State private var showsScanner = false
    @State private var scanNote: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Peering on “\(hostName)” is showing six digits.").stepDetail()

            PairingCodeCells(text: $enteredCode, isWrong: isWrong, focus: $focused, onEdit: { isWrong = false })
                .modifier(ShakeEffect(animatableData: shakes))
                .sensoryFeedback(.error, trigger: shakes)
                .onChange(of: enteredCode) { _, newValue in
                    let digits = String(newValue.filter(\.isNumber).prefix(6))
                    if digits != newValue { enteredCode = digits }
                    isWrong = false
                    if digits.count == 6 { check(digits) }
                }
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { focused = false }
                    }
                }

            Button {
                focused = false
                showsScanner = true
            } label: {
                Label("Scan QR code instead", systemImage: "qrcode.viewfinder")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .onAppear { takePairingLink() }
        // The keyboard waits out the step's own transition: raised in the same frame, its animation and the list's layout compete and the move to this step stutters.
        .task {
            try? await Task.sleep(for: .milliseconds(450))
            if submitted == nil { focused = true }
        }
        .onChange(of: model.pairingLink?.receivedAt) { takePairingLink() }
        .sheet(isPresented: $showsScanner) { scanner }
    }

    private func check(_ entered: String) {
        guard entered == code else { return reject() }
        focused = false
        submit(.typed)
    }

    private func reject() {
        isWrong = true
        withAnimation(.linear(duration: 0.4)) { shakes += 1 }
        focused = true
    }

    private func submit(_ kind: PairingSubmission, secret: Data? = nil) {
        submitted = kind
        model.confirmPairing(accepted: true, secret: secret)
    }

    /// A link from the system camera is the same act as scanning in the app. Older than a minute it is a leftover from an earlier attempt, and the Mac's code has since changed.
    private func takePairingLink() {
        guard let link = model.pairingLink, submitted == nil else { return }
        model.pairingLink = nil
        guard Date().timeIntervalSince(link.receivedAt) < 60 else { return }
        let payload = link.url.absoluteString
        guard let scanned = PairingPayload.code(from: payload) else { return }
        accept(scanned, payload: payload)
    }

    private func accept(_ scanned: String, payload: String) {
        enteredCode = scanned
        if scanned == code {
            submit(.scanned, secret: PairingPayload.secret(from: payload))
        } else {
            reject()
        }
    }

    private var scanner: some View {
        NavigationStack {
            PairingCodeScanner { payload in
                // **`false` rather than a bare `return`.** The scanner retires itself on a code it has taken, and it used to decide that before this ran: one wrong code in frame, and the camera went on showing a live picture that it would never report anything from again. Refusing here leaves it armed, and the sentence is what stops a refusal from looking like a broken camera.
                guard let scannedCode = PairingPayload.code(from: payload) else {
                    scanNote = String(localized: "That is not a pairing code. Point the camera at the code shown on your Mac.")
                    return false
                }
                scanNote = nil
                showsScanner = false
                accept(scannedCode, payload: payload)
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
                        .transition(.opacity)
                }
            }
            .ignoresSafeArea()
            .navigationTitle("Scan your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .sheetToolbar(onCancel: { showsScanner = false })
        }
        .presentationDetents([.medium, .large])
    }
}
