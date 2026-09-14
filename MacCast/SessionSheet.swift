import RemoteCore
import SwiftUI

struct SessionSheet: View {
    @Environment(SessionModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            List {
                Section("Stream") {
                    NavigationLink {
                        SourceList()
                            .navigationTitle("What to share")
                    } label: {
                        Label("Display, app or window", systemImage: "rectangle.on.rectangle")
                    }
                }

                Section("Session") {
                    LabeledContent("Mac", value: model.hostName ?? "—")
                    LabeledContent("State", value: stateDescription)
                    LabeledContent("Video", value: model.videoStatus)
                    if let latency = model.latencyMilliseconds {
                        LabeledContent("Control latency", value: "\(Int(latency.rounded())) ms")
                    }
                    LabeledContent("This device", value: model.thisDeviceDescription)
                }

                Section("Keyboard") {
                    Picker("Mode", selection: Binding(
                        get: { model.keyboardMode },
                        set: { model.setKeyboardMode($0) }
                    )) {
                        ForEach(KeyboardMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(model.keyboardMode.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Macros") {
                    ForEach(Macro.defaults) { macro in
                        Button(macro.title) { model.run(macro) }
                    }
                }

                Section("Diagnostics") {
                    if model.notes.isEmpty {
                        Text("Nothing to report yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(model.notes.enumerated()), id: \.offset) { _, note in
                            Text(note).font(.caption)
                        }
                    }
                }

                Section("Paired Macs") {
                    if model.pairedHostIDs.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.pairedHostIDs, id: \.self) { hostID in
                            Button(role: .destructive) {
                                model.forget(hostID: hostID)
                            } label: {
                                Text("Forget \(hostID)")
                            }
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        confirmReset = true
                    } label: {
                        Text("Reset this device's identity")
                    }
                } footer: {
                    Text("Generates a new key and a new device ID. Every Mac that knows this device must pair with it again.")
                }
            }
            .navigationTitle("Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Reset this device's identity?",
                isPresented: $confirmReset,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) {
                    model.resetDeviceIdentity()
                    dismiss()
                }
            } message: {
                Text("Every Mac you have paired with will treat this device as a new one.")
            }
        }
    }

    private var stateDescription: String {
        switch model.phase {
        case .idle: return "Idle"
        case .connecting: return "Connecting"
        case .handshaking: return "Handshaking"
        case .confirming: return "Waiting for the code comparison"
        case .ready: return "Connected"
        case .failed(let message): return "Failed — \(message)"
        case .disconnected: return "Disconnected"
        }
    }
}
