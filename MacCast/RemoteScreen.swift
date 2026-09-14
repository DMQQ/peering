import RemoteCore
import SwiftUI

/// The remote desktop itself: picture, pointer, keyboard, and the controls for all three.
struct RemoteScreen: View {
    @Environment(SessionModel.self) private var model

    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var canvasSize: CGSize = .zero
    @State private var showSheet = false
    /// Set once the user has actually dragged a finger, so the first contact is not read as a
    /// click on whatever happened to be under it.
    @State private var scrollMode = false

    private let minimumZoom: CGFloat = 0.5
    private let maximumZoom: CGFloat = 8

    var body: some View {
        // `Environment` gives the object but no projected value, so a local `@Bindable` is
        // what turns `model.showKeyboard` into something the keyboard view can bind to.
        @Bindable var model = model
        return ZStack {
            Color.black.ignoresSafeArea()

            video
            gestures

            VStack(spacing: 0) {
                statusBar
                Spacer(minLength: 0)
                controls
            }

            if case .confirming(let code) = model.phase {
                PairingPrompt(code: code, hostName: model.hostName ?? "this Mac")
            }

            if model.phase == .connecting || model.phase == .handshaking {
                ProgressOverlay(
                    title: model.phase == .connecting ? "Connecting…" : "Securing the connection…",
                    detail: model.hostName
                )
            }
        }
        // The keyboard must not resize the picture. A remote desktop whose view shrinks every
        // time the system keyboard appears would move every control the user is aiming at.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .background {
            KeyboardCapture(model: model, isFocused: $model.showKeyboard)
                .frame(width: 0, height: 0)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { canvasSize = $0 }
        .sheet(isPresented: $showSheet) { SessionSheet() }
    }

    // MARK: - Picture

    private var video: some View {
        VideoLayerView(renderer: model.renderer)
            .scaleEffect(zoom, anchor: .center)
            .offset(pan)
            .ignoresSafeArea()
    }

    // MARK: - Gestures

    private var gestures: some View {
        CanvasGestureView(
            onTouchDown: { point in
                guard let normalized = normalized(point) else { return }
                // Down *before* the move would be wrong: the host injects a press at the
                // position of the last move it saw, so the order is move-then-press and the
                // coalescer is what guarantees the move gets out first.
                model.send(.mouseMove(to: normalized))
                model.send(.mouseDown(button: .left))
            },
            onTouchMove: { point in
                guard let normalized = normalized(point) else { return }
                model.send(.mouseMove(to: normalized))
            },
            onTouchUp: { point in
                guard let normalized = normalized(point) else { return }
                model.send(.mouseMove(to: normalized))
                model.send(.mouseUp(button: .left))
            },
            onSecondaryClick: { point in
                guard let normalized = normalized(point) else { return }
                model.send(.mouseMove(to: normalized))
                model.send(.mouseDown(button: .right))
                model.send(.mouseUp(button: .right))
            },
            onScroll: { translation in
                // Doubled into pixels, which is the unit the host's wheel event is built in
                // (`units: .pixel`). A point of finger travel moving one pixel would make
                // scrolling a page take several swipes.
                model.send(.scroll(dx: Double(translation.width) * 2, dy: Double(translation.height) * 2))
            },
            onZoom: { factor, _ in
                zoom = min(max(zoom * factor, minimumZoom), maximumZoom)
                // Zoomed in, a two-finger drag is far more useful for moving the view than for
                // scrolling the Mac; zoomed out, the reverse.
                scrollMode = zoom > 1.01
                if zoom <= 1.01 { pan = .zero }
            },
            onPanCanvas: { translation in
                pan.width += translation.width
                pan.height += translation.height
            },
            twoFingerPansCanvas: scrollMode
        )
        .ignoresSafeArea()
    }

    private func normalized(_ point: CGPoint) -> NormalizedPoint? {
        CanvasGeometry.normalized(
            point: point,
            bounds: canvasSize,
            pixelSize: model.capturePixelSize,
            zoom: zoom,
            pan: pan
        )
    }

    // MARK: - Status

    private var statusBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "display")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.hostName ?? "Mac")
                    .font(.subheadline.weight(.semibold))
                Text(model.videoStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let latency = model.latencyMilliseconds {
                Text("\(Int(latency.rounded())) ms")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(latency < 40 ? .green : (latency < 120 ? .yellow : .orange))
            }

            if zoom > 1.01 {
                Button {
                    zoom = 1
                    pan = .zero
                    scrollMode = false
                } label: {
                    Text("\(Int((zoom * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Button {
                model.disconnect()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Disconnect")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 10) {
            if model.showKeyboard, !model.typedPreview.isEmpty {
                HStack {
                    Text(model.typedPreview)
                        .font(.system(.footnote, design: .monospaced))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            MacroBar()

            HStack(spacing: 12) {
                ModifierBar()

                Spacer(minLength: 8)

                Button {
                    model.setKeyboardMode(model.keyboardMode == .unicode ? .keycode : .unicode)
                } label: {
                    Text(model.keyboardMode.label)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(model.keyboardMode == .keycode
                                    ? Color.accentColor : Color.white.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Keyboard mode: \(model.keyboardMode.label)")

                Button {
                    model.showKeyboard.toggle()
                } label: {
                    Image(systemName: model.showKeyboard ? "keyboard.fill" : "keyboard")
                        .frame(width: 42, height: 34)
                        .background(model.showKeyboard ? Color.accentColor : Color.white.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("System keyboard")

                Button {
                    showSheet = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 42, height: 34)
                        .background(Color.white.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Session settings")
            }

            HStack(alignment: .center, spacing: 14) {
                JoystickView(
                    onMove: { travel in
                        model.send(.joystickMove(dx: Double(travel.width), dy: Double(travel.height)))
                    },
                    pointSize: model.capturePointSize
                )
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 18)
        .background(.ultraThinMaterial)
    }
}

/// The blocking pairing prompt.
///
/// An overlay rather than a sheet, so it cannot be dismissed by a swipe. The connection is
/// waiting on this answer: dismissing it without deciding would leave the session stalled
/// with no way back to the question.
struct PairingPrompt: View {
    @Environment(SessionModel.self) private var model
    let code: String
    let hostName: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)

                Text("Confirm the code")
                    .font(.title3.weight(.semibold))

                Text("This code should match the one shown on “\(hostName)”.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text(code)
                    .font(.system(size: 44, weight: .semibold, design: .monospaced))
                    .tracking(6)
                    .padding(.vertical, 4)

                Text("If the Mac shows different digits, something is impersonating it. Decline and check the network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    Button(role: .cancel) {
                        model.confirmPairing(accepted: false)
                    } label: {
                        Text("They differ").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        model.confirmPairing(accepted: true)
                    } label: {
                        Text("They match").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(26)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .padding(28)
        }
    }
}

struct ProgressOverlay: View {
    let title: String
    let detail: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text(title).font(.headline)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }
}

/// Session details, the capture-source picker, and the two destructive actions.
struct SessionSheet: View {
    @Environment(SessionModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            List {
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
