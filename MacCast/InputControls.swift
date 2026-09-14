import RemoteCore
import SwiftUI

/// A relative pointer control.
///
/// The canvas moves the cursor to where a finger touches, which is the right model for
/// pointing at something specific and the wrong one for the small corrections that make up
/// most of using a computer: reaching a menu bar, nudging a slider, getting back to a button
/// the finger is covering. A joystick does those, because it is relative.
///
/// The deltas are computed per unit **time**, not per touch sample. A trackpad-style
/// per-sample delta would double the cursor speed on a 120 Hz display relative to a 60 Hz
/// one, which is a bug that only shows up on some hardware.
struct JoystickView: View {
    /// Called with the travel for this sample, in the Mac's display points.
    var onMove: (CGSize) -> Void
    var pointSize: CGSize

    /// Fraction of the captured surface travelled per second at full deflection.
    private static let travelPerSecond = 0.9
    /// A gap longer than this is a new gesture, not a slow one — otherwise the first sample
    /// of a new drag carries all the time since the last one and the cursor jumps.
    private static let maximumSampleGap: TimeInterval = 0.05

    @State private var knob: CGSize = .zero
    @State private var lastSample: Date?

    private let radius: CGFloat = 44

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                .frame(width: radius * 2, height: radius * 2)

            Circle()
                .fill(.white.opacity(0.85))
                .frame(width: 34, height: 34)
                .offset(knob)
                .shadow(radius: 2)
        }
        .frame(width: radius * 2, height: radius * 2)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let raw = CGSize(
                        width: value.location.x - radius,
                        height: value.location.y - radius
                    )
                    // Clamped to the ring, so a finger that wanders off the pad keeps pushing
                    // at full deflection instead of reporting a magnitude the Mac would scale
                    // into an implausibly large jump.
                    let distance = max(hypot(raw.width, raw.height), 0.0001)
                    let limited = distance > radius
                        ? CGSize(width: raw.width * radius / distance, height: raw.height * radius / distance)
                        : raw
                    knob = limited
                    emit(limited)
                }
                .onEnded { _ in
                    knob = .zero
                    lastSample = nil
                }
        )
        .accessibilityLabel("Relative pointer")
        .accessibilityHint("Drag to nudge the cursor on the Mac")
    }

    private func emit(_ offset: CGSize) {
        let now = Date()
        // The very first sample has no interval to measure, so it contributes nothing: it has
        // not been held for any length of time yet.
        let interval = lastSample.map { min(now.timeIntervalSince($0), Self.maximumSampleGap) } ?? 0
        lastSample = now
        guard interval > 0 else { return }

        // Deflection, 0…1 on each axis, scaled by how far the surface should be crossed in a
        // second. A short sample interval produces a proportionally small nudge, which is what
        // keeps the cursor's speed the same whether the screen samples at 60 or 120 Hz.
        let dx = Double(offset.width / radius) * Self.travelPerSecond * pointSize.width * interval
        let dy = Double(offset.height / radius) * Self.travelPerSecond * pointSize.height * interval
        guard dx.isFinite, dy.isFinite, dx != 0 || dy != 0 else { return }
        onMove(CGSize(width: dx, height: dy))
    }
}

/// The modifier keys, as latching buttons.
///
/// Latching rather than momentary, because a touch screen cannot hold ⌘ with one hand and
/// type with the other. Each button posts a real modifier key press and release — see
/// ``SessionModel/toggleModifier(_:keyCode:)`` for why flag bits on the next keystroke are
/// not equivalent.
struct ModifierBar: View {
    @Environment(SessionModel.self) private var model

    /// Left-hand virtual keycodes. The protocol collapses left and right into one bit, so
    /// which side is pressed cannot be observed by the Mac.
    private static let keys: [(title: String, bit: Modifiers, code: UInt16)] = [
        ("⌘", .command, 55),
        ("⇧", .shift, 56),
        ("⌥", .option, 58),
        ("⌃", .control, 59),
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Self.keys, id: \.title) { key in
                let isOn = model.latchedModifiers.contains(key.bit)
                Button {
                    model.toggleModifier(key.bit, keyCode: key.code)
                } label: {
                    Text(key.title)
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 38, height: 34)
                        .background(isOn ? Color.accentColor : Color.white.opacity(0.14))
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(key.title)
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        }
    }
}

/// One-tap shortcuts.
struct MacroBar: View {
    @Environment(SessionModel.self) private var model
    var macros: [Macro] = Macro.defaults

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(macros) { macro in
                    Button {
                        model.run(macro)
                    } label: {
                        Text(macro.title)
                            .font(.system(size: 14, weight: .medium))
                            .padding(.horizontal, 10)
                            .frame(height: 34)
                            .background(Color.white.opacity(0.14))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

/// The capture-source picker, driven entirely by the host's `catalog` message.
///
/// Nothing here is hardcoded: the host enumerates the displays it has, the applications that
/// are running and the windows that are open, and this renders whatever it is given. A client
/// that guessed at sources would offer entries the Mac cannot capture, and would go stale the
/// moment a display was unplugged.
struct SourcePicker: View {
    @Environment(SessionModel.self) private var model

    var body: some View {
        Group {
            if let catalog = model.catalog, !catalog.all.isEmpty {
                List {
                    section("Displays", catalog.displays)
                    section("Applications", catalog.applications)
                    section("Windows", catalog.windows)
                }
            } else {
                ContentUnavailableView(
                    "No capture sources",
                    systemImage: "rectangle.on.rectangle.slash",
                    description: Text("The Mac has not sent its list of displays and windows yet.")
                )
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ descriptors: [CaptureSourceDescriptor]) -> some View {
        if !descriptors.isEmpty {
            Section(title) {
                ForEach(descriptors) { descriptor in
                    Button {
                        model.selectSource(descriptor)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: symbol(for: descriptor.kind))
                                .frame(width: 22)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(descriptor.title)
                                if let subtitle = descriptor.subtitle {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if descriptor.id == model.activeSourceID {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func symbol(for kind: CaptureSourceDescriptor.Kind) -> String {
        switch kind {
        case .display: return "display"
        case .application: return "app"
        case .window: return "macwindow"
        }
    }
}
