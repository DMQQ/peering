import RemoteCore
import SwiftUI
import UIKit

struct RemotePairingSheet: View {
    @Environment(SessionModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var identifier = ""

    /// The two are kept together so the sentence disappears exactly when the text it described
    /// does — the alternative, clearing it from `onChange`, is a race: a scan sets the field
    /// and submits in the same turn, and the change callback runs after that and would wipe the
    /// very refusal the scan produced.
    private struct Refusal: Equatable {
        let text: String
        let error: PairingPayloadError
    }

    @State private var refusal: Refusal?
    @State private var showsScanner = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                TabScreenHeader(String(localized: "Pair from Another Network"))

                Controls.card(String(localized: "Device ID"), footer: footer) {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Paste or type it here", text: $identifier, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)
                            .submitLabel(.go)
                            .font(.system(size: 15, design: .monospaced))
                            .textFieldStyle(.plain)
                            .focused($fieldFocused)
                            .onSubmit(submit)
                            // Wrapping rather than kept to one line: this is 36 characters of
                            // hexadecimal, and a field that scrolls sideways hides the back half
                            // of the very thing the user came here to check.
                            .lineLimit(1...3)
                            .padding(12)
                            .background(
                                .white.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )

                        Controls.divider

                        fillRow(String(localized: "Paste from the clipboard"), systemImage: "doc.on.clipboard") {
                            if let text = UIPasteboard.general.string { identifier = text }
                        }

                        Controls.divider

                        fillRow(String(localized: "Scan the code on the Mac"), systemImage: "qrcode.viewfinder") {
                            fieldFocused = false
                            showsScanner = true
                        }
                    }
                }

                if let refusal, refusal.text == identifier {
                    Text(refusal.error.errorDescription ?? String(localized: "That is not a Mac's device ID."))
                        .font(.caption)
                        .foregroundStyle(ColorPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !model.allowsRelay {
                    Text("Remote access is turned off in Settings. Turn it on to reach a Mac from another network.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(action: submit) {
                    Label("Pair", systemImage: "arrow.right")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.borderedProminent)
                // Both states are named rather than left to the button style. With the tint held
                // at ink and the label held at black, the disabled state was a black label on the
                // near-black the style dims a white fill to: the sheet opened with its one
                // button invisible, which reads as a broken screen rather than as a full one.
                .tint(canPair ? ColorPalette.ink : .white.opacity(0.16))
                .foregroundStyle(canPair ? ColorPalette.onInk : .white.opacity(0.55))
                .disabled(!canPair)

                Spacer(minLength: 0)
            }
            .padding(24)
            .background(ColorPalette.backdrop)
            .toolbar(.hidden, for: .navigationBar)
            .presentationDragIndicator(.visible)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .sheet(isPresented: $showsScanner) {
            NavigationStack {
                PairingCodeScanner { payload in
                    showsScanner = false
                    identifier = payload
                    submit()
                    return true
                }
                .ignoresSafeArea()
                .navigationTitle("Scan the Mac's code")
                .navigationBarTitleDisplayMode(.inline)
                .sheetToolbar(onCancel: { showsScanner = false })
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var canPair: Bool {
        !model.isBusy
            && model.allowsRelay
            && !identifier.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func fillRow(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Controls.row(title, systemImage: systemImage) {
                EmptyView()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RailButtonStyle(scale: 0.98))
        .accessibilityLabel(title)
    }

    private var footer: String {
        """
        The ID is on the Mac's Devices screen. Someone has to be at the Mac either way: it shows \
        six digits, you type them here, and the pairing finishes only when they match.
        """
    }

    private func submit() {
        fieldFocused = false
        if let failure = model.pairWithRemoteMac(hostID: identifier) {
            refusal = Refusal(text: identifier, error: failure)
        } else {
            dismiss()
        }
    }
}
