import PeeringKit
import RemoteCore
import SwiftUI

enum AttachSource { case photos, files }

struct AgentComposer: View {
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool
    let isWorking: Bool
    let canSend: Bool
    let send: () -> Void
    var attach: ((AttachSource) -> Void)?
    let stop: () -> Void

    /// While a turn runs, typing turns Stop into a send that queues.
    private var showsStop: Bool { isWorking && !canSend }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: InputBar.height / 2, style: .continuous)
        HStack(alignment: .bottom, spacing: 8) {
            InputCapsule(alignment: .bottom) {
                if let attach {
                    Menu {
                        Button { attach(.photos) } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
                        Button { attach(.files) } label: { Label("Files", systemImage: "folder") }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 28, height: 44)
                            .contentShape(Rectangle())
                    }
                    .menuOrder(.fixed)
                    .disabled(isWorking)
                    .opacity(isWorking ? 0.4 : 1)
                    .accessibilityLabel("Attach a file")
                }

                TextField(isWorking ? "Queue a message…" : "Message", text: $text, axis: .vertical)
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .lineLimit(1...6)
                    .focused($isFocused)
                    .padding(.vertical, 12)
            }
            .overlay {
                shape.strokeBorder(.white.opacity(isFocused ? 0.3 : 0), lineWidth: 1)
            }
            .runningEdge(isWorking, radius: InputBar.height / 2)
            .contentShape(shape)
            .onTapGesture { isFocused = true }
            .animation(Motion.tap, value: isFocused)

            InputSendButton(
                symbol: showsStop ? "stop.fill" : "arrow.up",
                isEnabled: showsStop || canSend,
                filled: !showsStop,
                label: showsStop ? "Stop" : (isWorking ? "Queue" : "Send")
            ) {
                showsStop ? stop() : send()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}
