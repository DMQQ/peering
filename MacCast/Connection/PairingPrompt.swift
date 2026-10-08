import RemoteCore
import SwiftUI
import UIKit

/// An overlay rather than a sheet, so it cannot be dismissed by a swipe. The connection is
/// waiting on this answer: dismissing it without deciding would leave the session stalled
/// with no way back to the question.
struct PairingPrompt: View {
    @Environment(SessionModel.self) private var model
    let code: String
    let hostName: String
    @State private var enteredCode = ""
    @State private var showsMismatch = false
    @State private var showsScanner = false

    @State private var scanNote: String?

    @FocusState private var codeFieldFocused: Bool

    /// sat directly in the session `ZStack` with nothing to size itself against but the picture
    /// behind it, so on a Mac's full display width the six digits, the icon and both buttons all
    /// grew to match — a phone-sized question stretched into a poster. A card asking for six
    /// digits does not get more legible at 1200 points than it is at 400.
    private static let cardWidth: CGFloat = 400

    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 34))
                    .foregroundStyle(ColorPalette.accent)

                Text("Enter the code from your Mac")
                    .font(.title3.weight(.semibold))

                Text("Peering on “\(hostName)” is showing six digits.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                TextField("000 000", text: $enteredCode)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.system(size: 38, weight: .semibold, design: .monospaced))
                    .tracking(7)
                    .multilineTextAlignment(.center)
                    .focused($codeFieldFocused)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .rowSurface()
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { codeFieldFocused = false }
                        }
                    }
                    .onChange(of: enteredCode) { _, newValue in
                        let digits = newValue.filter(\.isNumber)
                        enteredCode = String(digits.prefix(6))
                        showsMismatch = false
                        if enteredCode.count == 6 { codeFieldFocused = false }
                    }

                Text(showsMismatch
                     ? "That code does not match. Check the Mac and try again."
                     : "The code is checked on this device and is never used as a reusable password.")
                    .font(.caption)
                    .foregroundStyle(showsMismatch ? ColorPalette.danger : .secondary)
                    .multilineTextAlignment(.center)

                Button {
                    showsScanner = true
                } label: {
                    Label("Scan QR code", systemImage: "qrcode.viewfinder")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                }
                .buttonStyle(.bordered)
                .tint(.white.opacity(0.5))

                HStack(spacing: 12) {
                    Button(role: .cancel) {
                        codeFieldFocused = false
                        model.confirmPairing(accepted: false)
                    } label: {
                        Text("Cancel")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white.opacity(0.16))
                    .foregroundStyle(.white)

                    Button {
                        codeFieldFocused = false
                        if enteredCode == code {
                            model.confirmPairing(accepted: true)
                        } else {
                            showsMismatch = true
                        }
                    } label: {
                        Text("Pair")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    // Named explicitly rather than left to the disabled system style, which dims a
                    // black label on `ink` to another near-black: a button that reads as broken
                    // rather than as a state waiting on six digits. See ``RemotePairingSheet``.
                    .tint(enteredCode.count == 6 ? ColorPalette.ink : .white.opacity(0.16))
                    .foregroundStyle(enteredCode.count == 6 ? ColorPalette.onInk : .white.opacity(0.55))
                    .disabled(enteredCode.count != 6)
                }
            }
            .padding(26)
            .frame(maxWidth: Self.cardWidth)
            .glassSurface(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(28)
        }
        .onAppear { codeFieldFocused = true }
        .sheet(isPresented: $showsScanner) {
            NavigationStack {
                PairingCodeScanner { payload in
                    // **`false` rather than a bare `return`.** The scanner retires itself on a
                    // code it has taken, and it used to decide that before this ran: one wrong
                    // code in frame, and the camera went on showing a live picture that it would
                    // never report anything from again. Refusing here leaves it armed, and the
                    // sentence is what stops a refusal from looking like a broken camera.
                    guard let scannedCode = PairingPayload.code(from: payload) else {
                        scanNote = String(localized: "That is not a pairing code. Point the camera at the code shown on your Mac.")
                        return false
                    }
                    scanNote = nil
                    showsScanner = false
                    enteredCode = scannedCode
                    if scannedCode == code {
                        model.confirmPairing(accepted: true)
                    } else {
                        showsMismatch = true
                    }
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

}
