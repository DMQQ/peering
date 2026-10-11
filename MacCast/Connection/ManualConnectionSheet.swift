import SwiftUI

/// Dials a Mac by its address and port, for a network where it cannot be found by name.
struct ManualConnectionSheet: View {
    @Environment(SessionModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// Named because the tint and `disabled` both read it and must not disagree.
    private var canConnect: Bool {
        !model.isBusy && !model.manualAddress.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                // The name in the display face, not a navigation title: an inline title is set by iOS in the system face (as ``RemotePairingSheet`` does).
                TabScreenHeader(String(localized: "Connect by Address"))

                HStack(spacing: 10) {
                    TextField("Mac address", text: $model.manualAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    TextField("Port", text: $model.manualPort)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .frame(width: 88)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                Button {
                    model.connectToManualAddress()
                    dismiss()
                } label: {
                    Label("Connect", systemImage: "arrow.right")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.borderedProminent)
                // Both states named: the style dims an ink fill to a grey a black label disappears into.
                .tint(canConnect ? ColorPalette.ink : .white.opacity(0.16))
                .foregroundStyle(canConnect ? ColorPalette.onInk : .white.opacity(0.55))
                .disabled(!canConnect)
            }
            .padding(24)
            .frame(maxHeight: .infinity, alignment: .top)
            // Nothing in the bar but Cancel and its background off: a grey strip across the sheet read as stray iOS.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        // Painted on the presentation rather than on the content, so it reaches behind the bar too.
        .presentationBackground(ColorPalette.backdrop)
        .presentationDetents([.height(268)])
        .preferredColorScheme(.dark)
    }
}
