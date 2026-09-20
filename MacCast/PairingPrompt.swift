import RemoteCore
import SwiftUI
import UIKit

/// The blocking pairing prompt.
///
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

    /// What to say about a code the scanner read and refused, if anything.
    ///
    /// Only ever about the last one: the scanner stays armed after a refusal, precisely so the
    /// next code gets the same chance, and a sentence about a code that is no longer in frame
    /// should go when the next one arrives.
    @State private var scanNote: String?

    @FocusState private var codeFieldFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)

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
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
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
                     : "The code is checked on this iPhone and is never used as a reusable password.")
                    .font(.caption)
                    .foregroundStyle(showsMismatch ? ColorPalette.ink : .secondary)
                    .multilineTextAlignment(.center)

                Button {
                    showsScanner = true
                } label: {
                    Label("Scan QR code", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                HStack(spacing: 12) {
                    Button(role: .cancel) {
                        codeFieldFocused = false
                        model.confirmPairing(accepted: false)
                    } label: {
                        Text("Cancel").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        codeFieldFocused = false
                        if enteredCode == code {
                            model.confirmPairing(accepted: true)
                        } else {
                            showsMismatch = true
                        }
                    } label: {
                        Text("Pair").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(enteredCode.count != 6)
                }
            }
            .padding(26)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(28)
        }
        .onAppear { codeFieldFocused = true }
        .sheet(isPresented: $showsScanner) {
            NavigationStack {
                PairingCodeScanner { payload in
                    // The parser lives in `RemoteCore` beside the encoder that drew the code
                    // and beside the one for the Mac's device ID, because the two codes are
                    // read by two screens and each has to refuse the other's — see
                    // ``PairingPayload``. It refuses anything that is not six digits, so a
                    // Mac's ID scanned here is refused here rather than carried on with.
                    //
                    // **`false` rather than a bare `return`.** The scanner retires itself on a
                    // code it has taken, and it used to decide that before this ran: one wrong
                    // code in frame, and the camera went on showing a live picture that it would
                    // never report anything from again. Refusing here leaves it armed, and the
                    // sentence is what stops a refusal from looking like a broken camera.
                    guard let scannedCode = PairingPayload.code(from: payload) else {
                        scanNote = "That is not a pairing code. Point the camera at the code shown on your Mac."
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
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showsScanner = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

}

