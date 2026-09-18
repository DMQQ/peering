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
                    // Mac's ID scanned here leaves the prompt exactly as it was.
                    guard let scannedCode = PairingPayload.code(from: payload) else { return }
                    showsScanner = false
                    enteredCode = scannedCode
                    if scannedCode == code {
                        model.confirmPairing(accepted: true)
                    } else {
                        showsMismatch = true
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

