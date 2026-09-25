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
        guard let base = NSImage(systemSymbolName: state.symbol, accessibilityDescription: nil)
        else { return NSImage() }

        // Falls back to the uncoloured symbol rather than to nothing: a template glyph is a
        // worse icon than this one and a far better one than an empty space in the menu bar.
        let coloured = base.withSymbolConfiguration(
            NSImage.SymbolConfiguration(paletteColors: [state.colour])
        ) ?? base
        coloured.isTemplate = false
        return coloured
    }
}

/// The menu itself. Built when it is opened, so the elapsed times are current to the second
/// the user looked rather than to whenever the model last changed.
struct HostMenuBarContent: View {
    @Environment(HostModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if !model.permissions.allRequiredGranted {
            Text("Setup required")
        } else if model.connectedClients.isEmpty {
            Text(model.status.isListening ? "Waiting for a device" : "Not hosting")
        } else {
            ForEach(model.connectedClients) { client in
                Text("\(client.name) · \(client.elapsedDescription())")
            }
        }

        Divider()

        if model.permissions.allRequiredGranted {
            Button(model.status.isListening ? "Stop hosting" : "Start hosting") {
                model.status.isListening ? model.stop() : model.start()
            }
        }

        Divider()

        resourceReadings

        Button(model.permissions.allRequiredGranted ? "Open Peering" : "Finish Setup…") {
            openWindow(id: MacCastHostApp.mainWindowID)
            // The window may open behind whatever has focus; a menu bar item that appears to do
            // nothing is worse than one that is missing.
            NSApp.activate()
        }

        Divider()

        // **The two switches, in the menu, because this is where the host is actually met.** It is
        // a background agent: the window is where it is set up and the menu is where it is glanced
        // at, and whether a Mac is allowed to sleep is the sort of thing somebody wants to decide
        // while looking at the Mac rather than after opening a window and finding a pane in it.
        // The same two switches the Settings pane draws, under the same two names.
        // **Above the lid switch, because it is the one more people want.** A Mac that idle-sleeps
        // cannot be reached from anywhere, which is the failure somebody opens this menu to fix:
        // they were out, they tapped their Mac on the phone, and nothing answered. The switch
        // below is about the lid and is the harder of the two — it needs an administrator rule —
        // and the two were the same subject in this menu until this line existed, so the only
        // thing offered for "I want to reach it" was the one that costs a password prompt.
        //
        // A display that goes dark is fine and deliberately not prevented here by anything new:
        // the control channel stays up, so terminals, SSH and the clipboard all work with the
        // screen off, and only the picture is black. What breaks everything is the *system*
        // sleeping, which is what this assertion stops.
        Toggle("Keep Mac reachable", isOn: Binding(
            get: { model.preventLidCloseSleep },
            set: { model.setPreventLidCloseSleep($0) }
        ))

        // **Shorter here than in the pane, and for the only reason that matters in a menu.** The
        // pane's sentence explains why; a menu item is one line at a fixed width, and a wrapped one
        // is unreadable. What somebody opening this menu needs is the answer, not the reasoning.
        if model.keepAwakeWithheld {
            Text("Not being held: this Mac sleeps on its own")
        }

        lidCloseItem

        // **The hours, where they are usually wanted.** The pane has the same two pickers; this is
        // the copy that matters, because the moment somebody notices the Mac is still up at eleven
        // at night is the moment they are looking at the menu, and sending them into a window to
        // fix it is how a setting goes unchanged.
        Menu("Awake hours") {
            Toggle("Awake \(model.keepAwakeStartHour):00 to \(model.keepAwakeEndHour):00 only", isOn: Binding(
                get: { model.keepAwakeScheduleEnabled },
                set: { model.setKeepAwakeSchedule(enabled: $0) }
            ))

            Divider()

            Picker("From", selection: Binding(
                get: { model.keepAwakeStartHour },
                set: { model.setKeepAwakeHours(start: $0, end: model.keepAwakeEndHour) }
            )) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(String(format: "%02d:00", hour)).tag(hour)
                }
            }

            Picker("To", selection: Binding(
                get: { model.keepAwakeEndHour },
                set: { model.setKeepAwakeHours(start: model.keepAwakeStartHour, end: $0) }
            )) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(String(format: "%02d:00", hour)).tag(hour)
                }
            }

            if model.keepAwakeScheduleEnabled, model.keepAwakeEndHour < model.keepAwakeStartHour {
                Text("Overnight")
            }
        }

        Divider()

        // The same draft the About pane builds, offered where the app is actually being looked at
        // when something has gone wrong. Nothing about the session is in it: the version and the
        // macOS release are the whole of what travels, which is what makes this a menu item rather
        // than a form to fill in.
        Button("Report an issue…") {
            NSWorkspace.shared.open(HostStatusView.reportURL)
        }

        Divider()

        Button("Quit Peering") {
            model.stop()
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// What this app is costing the Mac, in the menu, where somebody watching a mosaic is already
    /// looking.
    ///
    /// **Moved here from the window, and not merely relocated.** These were a card in the
    /// Overview section, which meant opening a window and finding the right part of it to answer a
    /// question that arrives while a session is running — is this heavy because of what I am doing,
    /// or is it always like this. The menu is where a menu bar app is actually met, and it is the
    /// same one gesture from anywhere.
    ///
    /// Menu rows are one string each rather than a label and a value, so the caption the tiles
    /// carried underneath their figures is folded into the line: "12% of this Mac" is the whole
    /// reading, and the part that says *of this Mac* is the part that matters, because every other
    /// CPU figure a person has seen is about the machine rather than about one process in it.
    ///
    /// `Text` is a disabled menu item, which is what a reading should be — it is not a thing to
    /// click, and a menu of things that look pressable and do nothing is worse than a menu of
    /// facts.
    @ViewBuilder
    private var resourceReadings: some View {
        let rates = model.resources.rates
        Text("Resources")
        Text("CPU \(rates.map(HostResourceSampler.cpuPercent) ?? "…") of this Mac")
        Text("Memory \(model.resources.memoryBytes > 0 ? HostResourceSampler.memoryText(model.resources.memoryBytes) : "…") in use")
        Text("Network \(rates.map { HostResourceSampler.networkText($0.bytesPerSecond) } ?? "…") sent")
    }

    /// The lid switch, or the way to set it up, depending on whether the rule is already in place.
    ///
    /// **A door rather than a switch that does nothing.** Turning this on needs an administrator
    /// rule installed once, and that first install raises a password dialog. Raised from a menu
    /// item, the dialog arrives with no explanation attached to it and no way to read one first,
    /// which is the wrong place to ask somebody for their password. So before the rule exists the
    /// menu offers the setup as a door into the pane where the explanation lives, and the switch
    /// itself appears only once flipping it is silent.
    @ViewBuilder
    private var lidCloseItem: some View {
        if model.lidCloseRuleInstalled == true {
            Toggle("Keep running with the lid closed", isOn: Binding(
                get: { model.keepRunningWithLidClosed },
                set: { wanted in Task { await model.setKeepRunningWithLidClosed(wanted) } }
            ))
            .disabled(model.lidCloseBusy)

            // The switch is what was asked for and the reading is what the Mac is doing, and the
            // two come apart after a crash or a hand edit. Said here as well as in the pane,
            // because the menu is where somebody looks when the Mac is doing something they did
            // not ask for and the window is closed.
            if model.keepRunningWithLidClosed, !model.keepAwakeWithheld,
               model.lidCloseSystemState == .off {
                Text("Not in force: this Mac still sleeps on a closed lid")
            }

            // **The reminder, where somebody will actually meet it.** The prompt in the window
            // only exists while the window does, and the window is usually shut: the menu bar item
            // is the one piece of this app that is always on screen, so the question waits here
            // until it is answered.
            if model.asksToReleaseKeepAwake {
                Button("Nobody is connected: let this Mac sleep") {
                    Task { await model.releaseKeepAwakeNow() }
                }
            }
        } else {
            Button("Keep running with the lid closed…") {
                openWindow(id: MacCastHostApp.mainWindowID)
                NSApp.activate()
            }
        }
    }
}
