import AppKit
import MacCastKit
import RemoteCore
import SwiftUI

/// What the menu bar icon is saying.
///
/// Four states rather than the two this had, and the third question is why: the icon is read
/// from across a room, and "is a device attached" without "is this Mac available at all" leaves
/// the most common state — hosting, nobody connected — looking like the least useful one.
enum HostMenuBarState {
    /// The app cannot host until its two required macOS permissions are granted.
    case setupRequired
    /// A device is attached and the screen is going out.
    case streaming
    /// Hosting, with at least one device paired. Reachable the moment one asks.
    case ready
    /// Hosting, but nothing has ever paired. Reachable, and to nobody.
    case waiting
    /// Not hosting at all.
    case stopped

    var symbol: String {
        switch self {
        case .streaming, .ready, .waiting: return "iphone"
        case .setupRequired: return "exclamationmark.triangle"
        case .stopped: return "iphone.slash"
        }
    }

    /// The system's own colours rather than picked ones, because this icon cannot adapt. See
    /// ``HostMenuBarLabel`` — a coloured glyph is no longer a template, which means it no longer
    /// follows the menu bar's light and dark appearance, so every one of these has to be legible
    /// on both. Apple's semantic colours are the ones with that property already worked out.
    var colour: NSColor {
        switch self {
        case .streaming: return .systemGreen
        case .ready: return .systemBlue
        case .waiting: return .secondaryLabelColor
        case .setupRequired: return .systemOrange
        case .stopped: return .systemRed
        }
    }

    var description: String {
        switch self {
        case .streaming: return "A device is connected"
        case .ready: return "Hosting, with a paired device"
        case .waiting: return "Hosting, with no device paired"
        case .setupRequired: return "Setup required"
        case .stopped: return "Not hosting"
        }
    }
}

/// The menu bar icon: whether a device is attached, and whether this Mac is available at all.
///
/// The host is a background agent, so this question is asked with the window shut — which is
/// almost always. The window is where the host is set up; this is where it is glanced at.
///
/// **Why the icon had to stop being a template to carry a colour.** macOS draws a menu bar extra
/// as a *template* image: it keeps the shape and paints it in the menu bar's own foreground
/// colour. A tint applied to a symbol is therefore discarded, and every state comes out the same
/// shade — which is exactly what this icon used to do, and why its two states had to differ by
/// shape instead.
///
/// The way out is not to ship a template. The symbol is rendered into an `NSImage` with the
/// colour already in it and `isTemplate` is turned off, which makes the colour part of the
/// artwork rather than a hint macOS is free to ignore.
///
/// The cost is that the icon no longer follows the menu bar's appearance on its own — see
/// ``HostMenuBarState/colour`` — and shape still carries the state as well, so it reads for
/// anyone who cannot tell the colours apart.
struct HostMenuBarLabel: View {
    let state: HostMenuBarState

    var body: some View {
        Image(nsImage: Self.image(for: state))
            .accessibilityLabel(state.description)
    }

    private static func image(for state: HostMenuBarState) -> NSImage {
        guard let pears = NSImage(named: "MenuBarPears") else { return NSImage() }
        let size = NSSize(width: 20, height: 18)
        // Drawn in the handler so `labelColor` resolves against the menu bar's appearance each
        // time; a coloured dot means the image cannot be a template.
        let image = NSImage(size: size, flipped: false) { rect in
            let glyph = NSRect(x: 0, y: 0, width: 18, height: 18)
            NSColor.labelColor.withAlphaComponent(state == .stopped ? 0.5 : 1).setFill()
            glyph.fill()
            pears.draw(in: glyph, from: .zero, operation: .destinationIn, fraction: 1)

            let dot = NSRect(x: rect.maxX - 7, y: 0, width: 7, height: 7)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            state.colour.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// The menu bar panel. A window-style extra rather than a menu, so it can carry live timers,
/// switches and readings instead of one disabled string per line.
struct HostMenuBarContent: View {
    @Environment(HostModel.self) private var model
    @Environment(Updater.self) private var updater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let version = updater.availableVersion {
                updateRow(version)
            }

            if !model.permissions.allRequiredGranted {
                setupCard
            } else {
                if !model.connectedClients.isEmpty {
                    devicesCard
                }
                awakeCard
                resourcesRow
            }

            footer
        }
        .background(PanelWindowEntrance())
        .padding(14)
        .frame(width: 320)
        .animation(HostMotion.state, value: model.connectedClients.count)
        .animation(HostMotion.state, value: updater.availableVersion)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 11) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 36, height: 36)
                                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Peering")
                    .font(HostDisplayFont.display(17))
                    .tracking(-0.4)
                    .foregroundStyle(Color.primary)
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                        .shadow(color: statusColor.opacity(0.7), radius: 3)
                    Text(statusText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if model.permissions.allRequiredGranted {
                powerButton
            }
        }
    }

    private var powerButton: some View {
        let on = model.status.isListening
        return Button {
            on ? model.stop() : model.start()
        } label: {
            Image(systemName: "power")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(on ? Color.white : Color.secondary)
                .frame(width: 32, height: 32)
                .background(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.08)), in: Circle())
                .overlay(Circle().strokeBorder(on ? .clear : Color.primary.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .help(on ? "Stop hosting" : "Start hosting")
        .accessibilityLabel(on ? "Stop hosting" : "Start hosting")
    }

    private var statusColor: Color {
        if !model.permissions.allRequiredGranted { return Color.orange }
        if !model.connectedClients.isEmpty { return Color.green }
        switch model.status {
        case .listening: return Color.accentColor
        case .starting, .idle: return Color.secondary.opacity(0.75)
        case .failed: return Color.red
        }
    }

    private var statusText: String {
        if !model.permissions.allRequiredGranted { return "Setup required" }
        if !model.connectedClients.isEmpty {
            let count = model.connectedClients.count
            return count == 1 ? "Streaming to 1 device" : "Streaming to \(count) devices"
        }
        switch model.status {
        case .idle: return "Not hosting"
        case .starting: return "Starting…"
        case .listening: return "Waiting for a device"
        case .failed(let message): return message
        }
    }

    // MARK: Cards

    private func updateRow(_ version: String) -> some View {
        Button { updater.check() } label: {
            HStack(spacing: 9) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update available")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.primary)
                    Text("Version \(version)")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                Spacer(minLength: 0)
                Text("Install")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.accentColor, in: Capsule())
            }
            .padding(10)
            .background(
                Color.accentColor.opacity(0.14),
                in: RoundedRectangle(cornerRadius: HostPalette.controlRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HostPalette.controlRadius, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.4))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(!updater.canCheck)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var setupCard: some View {
        card {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.orange)
                Text("Peering needs Screen Recording and Accessibility before a phone can connect.")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var devicesCard: some View {
        card(title: "Connected") {
            // A timeline rather than a formatted string, so the timers run while the panel is open.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: 8) {
                    ForEach(model.connectedClients) { client in
                        HStack(spacing: 9) {
                            Image(systemName: "iphone")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.primary)
                                .frame(width: 26, height: 26)
                                .background(Color.primary.opacity(0.08), in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(client.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Color.primary)
                                        .lineLimit(1)
                                    pathBadge(for: client)
                                }
                                Text(usageEstimate)
                                    .font(.caption2)
                                    .foregroundStyle(Color.secondary)
                                    .lineLimit(1)
                                    .contentTransition(.numericText())
                            }
                            Spacer(minLength: 0)
                            Text(client.elapsedDescription(now: context.date))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.secondary)
                                .contentTransition(.numericText())
                        }
                    }
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func pathBadge(for client: ConnectedClient) -> some View {
        let label = !client.viaRelay ? "LAN" : model.directPathOpen ? "P2P" : "RELAY"
        return Text(label)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(Color.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.18)))
            .help(!client.viaRelay ? "On this network" : model.directPathOpen
                ? "Over the internet, straight to the device" : "Over the internet, through the relay")
    }

    /// The host's own cost shared evenly across the attached devices, which is an estimate:
    /// capture and encoding are one pipeline, not one per device.
    private var usageEstimate: String {
        guard let rates = model.resources.rates else { return "Measuring…" }
        let share = Double(max(1, model.connectedClients.count))
        let cpu = HostResourceSampler.percent(rates.cpuOfMachine / share)
        return "≈ \(cpu) CPU · \(HostResourceSampler.networkText(rates.bytesPerSecond / share))"
    }

    private var awakeCard: some View {
        card(title: "Staying awake") {
            VStack(spacing: 10) {
                switchRow(
                    "Keep Mac reachable",
                    symbol: "wifi",
                    isOn: Binding(
                        get: { model.preventLidCloseSleep },
                        set: { model.setPreventLidCloseSleep($0) }
                    ),
                    note: model.keepAwakeWithheld ? "Not being held: this Mac sleeps on its own" : nil
                )

                lidCloseRow

                if model.asksToReleaseKeepAwake {
                    Button {
                        Task { await model.releaseKeepAwakeNow() }
                    } label: {
                        Text("Nobody is connected: let this Mac sleep")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(PressableStyle())
                }

                Divider().overlay(Color.primary.opacity(0.12))

                awakeHoursRow
            }
        }
    }

    @ViewBuilder
    private var lidCloseRow: some View {
        if model.lidCloseRuleInstalled == true {
            let notInForce = model.keepRunningWithLidClosed && !model.keepAwakeWithheld
                && model.lidCloseSystemState == .off
            switchRow(
                "Run with the lid closed",
                symbol: "laptopcomputer",
                isOn: Binding(
                    get: { model.keepRunningWithLidClosed },
                    set: { wanted in Task { await model.setKeepRunningWithLidClosed(wanted) } }
                ),
                note: notInForce ? "Not in force: this Mac still sleeps on a closed lid" : nil
            )
            .disabled(model.lidCloseBusy)
        } else {
            Button { openMainWindow() } label: {
                HStack(spacing: 9) {
                    rowIcon("laptopcomputer")
                    Text("Run with the lid closed")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.primary)
                    Spacer(minLength: 0)
                    Text("Set up")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.secondary.opacity(0.75))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
        }
    }

    private var awakeHoursRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            switchRow(
                "Only during set hours",
                symbol: "clock",
                isOn: Binding(
                    get: { model.keepAwakeScheduleEnabled },
                    set: { model.setKeepAwakeSchedule(enabled: $0) }
                ),
                note: nil
            )

            if model.keepAwakeScheduleEnabled {
                HStack(spacing: 6) {
                    hourPicker(
                        get: { model.keepAwakeStartHour },
                        set: { model.setKeepAwakeHours(start: $0, end: model.keepAwakeEndHour) }
                    )
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.secondary.opacity(0.75))
                    hourPicker(
                        get: { model.keepAwakeEndHour },
                        set: { model.setKeepAwakeHours(start: model.keepAwakeStartHour, end: $0) }
                    )
                    Spacer(minLength: 0)
                    if model.keepAwakeEndHour < model.keepAwakeStartHour {
                        Text("Overnight")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.secondary)
                    }
                }
                .padding(.leading, 35)
                .transition(.opacity)
            }
        }
        .animation(HostMotion.state, value: model.keepAwakeScheduleEnabled)
    }

    private func hourPicker(get: @escaping () -> Int, set: @escaping (Int) -> Void) -> some View {
        Menu {
            ForEach(0..<24, id: \.self) { hour in
                Button(String(format: "%02d:00", hour)) { set(hour) }
            }
        } label: {
            Text(String(format: "%02d:00", get()))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.primary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.08), in: Capsule())
    }

    private var resourcesRow: some View {
        let rates = model.resources.rates
        let memory = model.resources.memoryBytes
        return HStack(spacing: 8) {
            reading("CPU", rates.map(HostResourceSampler.cpuPercent) ?? "…")
            reading("Memory", memory > 0 ? HostResourceSampler.memoryText(memory) : "…")
            reading("Sent", rates.map { HostResourceSampler.networkText($0.bytesPerSecond) } ?? "…")
        }
    }

    private func reading(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            Text(label)
                .font(.caption2)
                .foregroundStyle(Color.secondary.opacity(0.75))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(
            RoundedRectangle(cornerRadius: HostPalette.controlRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        )
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button { openMainWindow() } label: {
                Text(model.permissions.allRequiredGranted ? "Open Peering" : "Finish Setup")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: HostPalette.controlRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: HostPalette.controlRadius, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())

            iconButton("exclamationmark.bubble", help: "Report an issue") {
                NSWorkspace.shared.open(HostStatusView.reportURL)
            }
            iconButton("power.circle", help: "Quit Peering") {
                model.stop()
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    // MARK: Pieces

    private func card<Content: View>(title: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.secondary.opacity(0.75))
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: HostPalette.controlRadius + 2, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        )
    }

    private func switchRow(_ title: String, symbol: String, isOn: Binding<Bool>, note: String?) -> some View {
        HStack(alignment: .top, spacing: 9) {
            rowIcon(symbol, lit: isOn.wrappedValue)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.primary)
                if let note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 5)
            Spacer(minLength: 0)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .padding(.top, 4)
        }
    }

    private func rowIcon(_ symbol: String, lit: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(lit ? Color.white : Color.secondary)
            .frame(width: 26, height: 26)
            .background(lit ? AnyShapeStyle(Color.accentColor.opacity(0.85)) : AnyShapeStyle(Color.primary.opacity(0.08)), in: Circle())
            .animation(HostMotion.state, value: lit)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.secondary)
                .frame(width: 30, height: 30)
                .overlay(
                    RoundedRectangle(cornerRadius: HostPalette.controlRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help(help)
        .accessibilityLabel(help)
    }

    private func openMainWindow() {
        // Closes the panel first; it would otherwise sit over the window it just opened.
        NSApp.keyWindow?.close()
        openWindow(id: MacCastHostApp.mainWindowID)
        NSApp.activate()
    }
}

/// Zooms the panel's window in from the menu bar, and back out when it closes.
///
/// Animated on the window rather than on its content: the system shows the panel at full
/// opacity, so it is caught here before the first frame and taken back to transparent.
private struct PanelWindowEntrance: NSViewRepresentable {
    final class Probe: NSView {
        private var observer: NSObjectProtocol?
        private var exitObserver: NSObjectProtocol?
        private var animating = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            guard let window else { return }
            animate(window)
            // The window is kept and reshown on every click, so each showing is its own entrance.
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.animate(window) }
            }
            exitObserver.map(NotificationCenter.default.removeObserver)
            exitObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.animateExit(from: window) }
            }
        }

        /// The panel is ordered out the moment it resigns key, so the exit plays on a snapshot
        /// in a stand-in window at the same place.
        private func animateExit(from window: NSWindow) {
            guard let content = window.contentView,
                  let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
            content.cacheDisplay(in: content.bounds, to: rep)
            let snapshot = NSImage(size: content.bounds.size)
            snapshot.addRepresentation(rep)

            let ghost = NSWindow(contentRect: window.frame, styleMask: .borderless, backing: .buffered, defer: false)
            ghost.isReleasedWhenClosed = false
            ghost.backgroundColor = .clear
            ghost.isOpaque = false
            ghost.hasShadow = true
            ghost.level = window.level
            ghost.ignoresMouseEvents = true
            // The snapshot cannot capture the panel's blurred material, so the ghost draws its own.
            let image = NSVisualEffectView(frame: content.bounds)
            image.material = .menu
            image.state = .active
            image.blendingMode = .behindWindow
            image.wantsLayer = true
            image.layer?.cornerRadius = 16
            image.layer?.cornerCurve = .continuous
            image.layer?.masksToBounds = true
            let picture = NSImageView(image: snapshot)
            picture.frame = content.bounds
            picture.autoresizingMask = [.width, .height]
            image.addSubview(picture)
            ghost.contentView = image
            ghost.orderFront(nil)

            if let layer = image.layer {
                let bounds = layer.bounds
                var to = CATransform3DMakeTranslation(bounds.midX, bounds.maxY, 0)
                to = CATransform3DScale(to, 0.75, 0.75, 1)
                to = CATransform3DTranslate(to, -bounds.midX, -bounds.maxY, 0)
                let zoom = CABasicAnimation(keyPath: "transform")
                zoom.fromValue = CATransform3DIdentity
                zoom.toValue = to
                zoom.duration = 0.2
                zoom.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.8, 0.4)
                zoom.fillMode = .forwards
                zoom.isRemovedOnCompletion = false
                layer.add(zoom, forKey: "exit")
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                ghost.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated { ghost.orderOut(nil) }
            }
        }

        private func animate(_ window: NSWindow) {
            // Both the first showing and becoming key arrive for the first click.
            guard !animating else { return }
            animating = true
            window.alphaValue = 0
            // Scaled about the top centre, so the panel grows out of the menu bar icon.
            window.contentView?.wantsLayer = true
            if let layer = window.contentView?.layer {
                let bounds = layer.bounds
                var from = CATransform3DMakeTranslation(bounds.midX, bounds.maxY, 0)
                from = CATransform3DScale(from, 0.75, 0.75, 1)
                from = CATransform3DTranslate(from, -bounds.midX, -bounds.maxY, 0)
                let zoom = CABasicAnimation(keyPath: "transform")
                zoom.fromValue = from
                zoom.toValue = CATransform3DIdentity
                zoom.duration = 0.32
                zoom.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.05)
                layer.add(zoom, forKey: "entrance")
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.animating = false }
            }
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) {}
}

private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(HostMotion.press, value: configuration.isPressed)
    }
}
