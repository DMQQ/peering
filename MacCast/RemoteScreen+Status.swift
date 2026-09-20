import MacCastKit
import RemoteCore
import SwiftUI
import UIKit

/// The status pill and the two dots beside it.
///
/// An extension rather than a file of its own type: state and its gestures have to
/// agree about what the picture is, and the view is easier to read in pieces than as
/// one file of two thousand lines. Members are `internal` here because Swift's
/// `private` is file-scoped — see the note in `RemoteScreen`.
extension RemoteScreen {
    // MARK: - Status

    /// The pill's outline, in whichever state it is in.
    ///
    /// A `RoundedRectangle` rather than the `Capsule` this was, and it is the corner radius that
    /// carries the animation: both the shape and the clip read from this one property, so the
    /// glass and the content it holds can never disagree about where the edge is — which is what
    /// a capsule's half-the-height corner was doing to the third row of the expanded panel.
    /// `continuous` because that is the curve iOS draws its own chrome with, and a circular
    /// corner beside it looks like a rectangle with the corners rounded off.
    var pillShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: statusBarExpanded
                ? ChromeMetrics.pillExpandedRadius
                : ChromeMetrics.pillCollapsedRadius,
            style: .continuous
        )
    }

    /// What the pill holds, arriving and leaving.
    ///
    /// Delayed on the way in, so the contents land into a shape that has already started to open
    /// rather than travelling with its frame. That lag is the half of the effect the frame cannot
    /// do by itself: content that arrives with the frame reads as a panel switched on inside a box
    /// that happens to be resizing, and content that lands into a frame already in motion reads as
    /// one object changing shape.
    ///
    /// Leaving is not animated at all, and that is not a shortcut. A view being removed stays in
    /// its parent's layout for as long as its removal transition runs — so while the expanded
    /// panel faded out, the stack it is in would still be measuring it, and the pill would sit at
    /// its *open* size for the length of that fade before starting to close. Gone in one frame,
    /// the stack is the collapsed size on the next, and the spring has the whole of the travel to
    /// animate. What covers the disappearance is the clip: the shape closes over the content it
    /// is letting go of.
    static let pillContents = AnyTransition.asymmetric(
        insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.06)),
        removal: .identity
    )

    /// The session's status, and the two things hung off its edge.
    ///
    /// The dots sit outside the glass rather than in the row that is inside it — see
    /// ``sessionDots`` — so the pill holds status and the dots hold the two occasional actions,
    /// and the outer `HStack` is what keeps them one object: attached, not merely near each other.
    var statusBar: some View {
        HStack(alignment: .center, spacing: 5) {
            // The dots are served first and the pill takes what is left. The pill was taking
            // the width it wanted, which on a portrait phone pushed the terminal dot off the
            // edge of the screen — and of the three, the dots are the ones with nowhere to
            // compress to, being circles with one glyph in them.
            lockDot.layoutPriority(1)
            statusPill
            terminalDot.layoutPriority(1)
        }
        // Narrower than the rails' own inset, on purpose: every point taken off the sides is a
        // point the pill's rows get, and the pill is the one piece of chrome that has to hold
        // three rows of other things.
        .padding(.horizontal, 6)
        // The same inset as the rails, so the pill and the panels hang from one line.
        .padding(.top, ChromeMetrics.edgeInset)
        .reportChromeFrame(.statusBar, into: $chromeFrames)
        .task(id: model.phase) {
            // Expand a moment when the session comes up, then collapse — through the same
            // function a tap uses, so there is one place that knows about the pending timer.
            guard model.phase == .ready else { return }
            expandStatusBar()
        }
    }

    var statusPill: some View {
        // A `ZStack`, and this is the whole of why the pill grows rather than being replaced.
        //
        // It was a `Group`, and a `Group` is transparent: every modifier on one is applied to
        // each of its children instead of to a container around them. So the glass, the clip and
        // the corner were not one shape being asked to change size — they were a shape *per
        // state*, and flipping the branch threw one away and built the other. There was nothing
        // whose frame could be animated, so the old pill faded out and a larger one faded in,
        // which is exactly what it looked like.
        //
        // A container has an identity that survives the change, and a frame is a thing with an
        // identity that can be interpolated. Top-aligned because the two states are briefly both
        // present, and the pill should only ever grow downwards.
        ZStack(alignment: .top) {
            if statusBarExpanded {
                VStack(alignment: .leading, spacing: 5) {
                    // ── Row 1: who, and the way out ─────────────────────────────────
                    //
                    // The name has this row to itself, which it did not before. It used to share
                    // with the clock, the latency and the quit button, and the arithmetic never
                    // worked on a phone held upright: "Damian's MacBook Pro" is the longest
                    // string in the pill by twice over, and the row could only fit it by
                    // clipping it. The readouts moved down to the second row, where they belong
                    // anyway — they describe the stream, and the stream's name is on the row
                    // above.
                    HStack(spacing: 10) {
                        // Green once the session is up rather than merely connected: a socket
                        // that is open but still handshaking is not something to reassure
                        // anyone about, and the phase is the only thing that knows the
                        // difference.
                        Circle()
                            .fill(model.phase == .ready ? Color.green : ColorPalette.ink)
                            .frame(width: 7, height: 7)
                        Text(model.hostName ?? "Mac")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        // The quit button is pinned to the far edge rather than sitting after the
                        // name. It is the one control here you reach for without reading, and it
                        // should be in the same place every time — which it was not, because the
                        // pill hugs its contents and the name is a different length on every Mac.
                        Spacer(minLength: 12)
                        // The session's only way out, always visible in the expanded pill.
                        Button { model.disconnect() } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14, weight: .bold))
                                Text("QUIT")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.red.opacity(0.85), in: Capsule())
                            // The label takes the width it needs and nothing offers to give it
                            // any back. A quit button reading "QUI / T" is one that has been
                            // compressed by the row, and there is no state in which that is the
                            // right way to spend the width.
                            .fixedSize()
                        }
                        .buttonStyle(RailButtonStyle(scale: 0.9))
                        .accessibilityLabel("Quit session")
                    }

                    // ── Row 2: what the stream is doing, and the controls for it ────
                    //
                    // One row, where there were two. The readouts and the controls are the same
                    // kind of thing to look at — a line of small facts about the session, some
                    // of which can be pressed — and splitting them cost the pill a whole row of
                    // height for two short strings. They fit together on a portrait phone with
                    // the chips a little tighter, and the pill is a line shorter for it.
                    HStack(spacing: 7) {
                        if let latency = model.shownLatency {
                            Text(String(format: "%3d ms", Int(latency.rounded())))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(ColorPalette.reading(latency))
                                .frame(width: 46, alignment: .trailing)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        connectionPathChip
                        qualityChip
                        soundButton
                        fillChip
                        // Lock and display dimming live in the dot beside the pill, leaving this
                        // row to describe and control the stream itself.
                        if zoom > 1.01 {
                            Button {
                                // The same reset the screen does for itself when the source
                                // changes, from the one definition of where the picture rests.
                                resetPicture()
                            } label: {
                                Text("\(Int((zoom * 100).rounded()))%")
                                    .monospacedDigit()
                                    .pillChip()
                            }
                            .buttonStyle(RailButtonStyle(scale: 0.9))
                        }
                        Button { ScreenshotShare.present() } label: {
                            Image(systemName: "camera")
                                .pillChip()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Take screenshot")
                    }
                }
                // Wider on the right than the left. What ends on that side is a control — the
                // quit button, the camera — and a control flush against the glass reads as
                // clipped; what ends on the left is a label, which is happy at the edge.
                .padding(.leading, 16)
                .padding(.trailing, 20)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
                // The other half of the toggle. The collapsed bar expands on a tap and the
                // expanded one closes on the next, so it is one control with one meaning
                // rather than a button that only ever goes one way.
                .onTapGesture { collapseStatusBar() }
                // Opacity only, and on its own clock — see ``pillContents``. The scale that was
                // here made the two states cross-fade as though they were unrelated, one
                // shrinking away while the other grew in; what they are is the two faces of one
                // shape, so the shape carries the movement and the contents just appear in it.
                .transition(Self.pillContents)
            } else {
                HStack(spacing: 8) {
                    // Green when the Mac is connected and sending, red when it is connected and
                    // has stopped. It was white, which said nothing: a dot that is always the
                    // same colour is decoration, and this one sits in the pill that already
                    // carries the Mac's name and the latency — the two facts whose whole purpose
                    // is to be read at a glance.
                    //
                    // Green rather than the palette's white because the host picker already
                    // spends green on "this Mac is reachable", and a second colour for the same
                    // fact would be two vocabularies for one thing.
                    // Two lines, where this was one running line of everything at once.
                    //
                    // The source's name is a whole sentence — "Built-in Retina Display" is
                    // seventeen characters of it — and it was being asked to share a single row
                    // with the Mac's name, the path, the frame rate and the latency. What that
                    // produced was four things competing for a line and the longest one losing:
                    // the row either truncated the answer to "what am I looking at" or pushed the
                    // latency off the end of it, depending on which Mac was connected.
                    //
                    // So the line is split by what it is about. Who and how fast it is going
                    // answers "is this working" and belongs on the first line; what is being
                    // shown and over which path answers "what am I looking at" and goes under it,
                    // indented past the dot so the two read as one block rather than as two rows
                    // that happen to be adjacent.
                    // The dot is part of the name's line rather than a mark floating beside the
                    // block. Centred against both lines it sat between them with a gap either
                    // side, which reads as a dot that lost its label — and the label is the Mac
                    // it is reporting on.
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 7) {
                            // Green when the Mac is connected and sending, red when it is
                            // connected and has stopped. It was white, which said nothing: a dot
                            // that is always the same colour is decoration, and this one sits in
                            // the pill that already carries the Mac's name and the latency — the
                            // two facts whose whole purpose is to be read at a glance.
                            //
                            // Green rather than the palette's white because the host picker
                            // already spends green on "this Mac is reachable", and a second
                            // colour for the same fact would be two vocabularies for one thing.
                            Circle()
                                .fill(model.isVideoStreaming ? Color.green : Color.red)
                                .frame(width: 6, height: 6)
                            Text(model.hostName ?? "Mac")
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            // No spacer, for the reason Row 1 has none: the collapsed pill
                            // should be the width of what it says.
                            if let latency = model.shownLatency {
                                Text(String(format: "%3d ms", Int(latency.rounded())))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(ColorPalette.reading(latency))
                                    .frame(width: 46, alignment: .trailing)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                        }

                        HStack(spacing: 6) {
                            if let sourceTitle = model.activeSourceTitle {
                                Text(sourceTitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            connectionPathChip
                        }
                        // Under the Mac's name rather than under the dot, which is what makes the
                        // second line read as a continuation of the first.
                        .padding(.leading, 13)
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 20)
                .padding(.vertical, 8)
                // Two lines rather than one, and a fixed height for the same reason it was fixed
                // before: a pill that resized itself as a source changed would move the picture
                // under a finger that is aiming at it.
                //
                // The height and the padding have to be read together, which is what went wrong
                // the first time. Padding applied *before* a fixed frame lives inside it, so
                // The frame leaves enough room for two lines without turning the collapsed
                // status into a panel. The padding is kept inside the fixed height so source
                // changes never move the picture underneath it.
                .frame(height: 56)
                .onTapGesture { expandStatusBar() }
                .contentShape(pillShape)
                // Opacity only, and on its own clock — see ``pillContents``. The scale that was
                // here made the two states cross-fade as though they were unrelated, one
                // shrinking away while the other grew in; what they are is the two faces of one
                // shape, so the shape carries the movement and the contents just appear in it.
                .transition(Self.pillContents)
            }
        }
        // Clipped to the shape, not to the rectangle it is drawn in. `.clipped()` cut the
        // contents off at the corners of the *bounds*, which left them showing outside the
        // rounded edge and over the picture behind — and the fix is not a smaller corner, it is
        // clipping to the same outline the glass is drawn in.
        //
        // It also carries the mid-flight case: the pill's content is laid out at its final size
        // from the first frame of the spring, so without this the expanded panel hangs below a
        // background that has not caught up to it yet.
        .clipShape(pillShape)
        .glassSurface(in: pillShape)
    }

    /// What the two dots add to the pill's width: a dot and a gap on each side.
    static let sessionDotsWidth: CGFloat = (48 + 7) * 2

    /// How wide the pill itself is allowed to get.
    ///
    /// Wide enough that its two rows fit without wrapping: the Mac's name, the clock, the latency
    /// and the quit button on one line, and the path, the quality picker, the fill and the two
    /// tools on the next. At 420 the name wrapped onto two lines and pushed QUIT off its own —
    /// which is what "QUI / T" was. The cap is still a cap: on a wide landscape screen the pill
    /// stops growing rather than turning into a bar across the top of the picture.
    static let pillMaxWidth: CGFloat = 440

    /// One dot, on the side of the pill that suits it.
    ///
    /// PiP and the terminal were two more capsules in a row that already held four, which is what
    /// made the pill read as a toolbar with a status line at the top of it. Out here they are what
    /// they actually are — two occasional things this session can also do — and the pill goes back
    /// to saying what is happening.
    ///
    /// Split to the two edges rather than stacked on one: the pill spends most of its life
    /// collapsed and is the widest thing on a landscape screen, so a pair hanging off one end
    /// pulls it visibly off-centre. One either side balances it, and it also separates two actions
    /// that have nothing to do with each other.
    ///
    /// This side was PiP's, and PiP does not belong here: iOS floats the picture by itself when
    /// the app goes away, so the button started something that had already happened. What it was
    /// actually good for was trying PiP *without* leaving and recording why it refused — a
    /// diagnostic, and one that belongs beside the switch it explains, in Settings.
    ///
    /// Tap locks immediately. A hold opens the two related ways to leave the physical Mac alone:
    /// lock the session, or dim its displays while keeping the remote picture alive.
    var lockDot: some View {
        Button {
            model.lockMac()
        } label: {
            Image(systemName: model.privacyModeEnabled ? "lock.shield.fill" : "lock.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(model.privacyModeEnabled ? ColorPalette.accent : ColorPalette.ink)
                .frame(width: 48, height: 48)
                .glassSurface(in: Circle())
        }
        .contentShape(Rectangle())
        .buttonStyle(RailButtonStyle(scale: 0.92))
        .contextMenu {
            // Tinted per item rather than on the closure: a modifier on the menu's own content is
            // not a thing SwiftUI offers, so each row says it for itself.
            Button { model.lockMac() } label: {
                Label("Lock screen", systemImage: "lock.fill")
            }
            .menuInk()
            Button { model.setPrivacyMode(!model.privacyModeEnabled) } label: {
                Label(
                    model.privacyModeEnabled ? "Restore display brightness" : "Dim displays",
                    systemImage: model.privacyModeEnabled ? "sun.max.fill" : "sun.min.fill"
                )
            }
            .menuInk()
        }
        .accessibilityLabel("Lock the Mac")
        .accessibilityHint("Touch and hold for Lock Screen or Dim Displays")
    }

    /// The terminal, and the two things about it worth knowing from the session screen: that
    /// shells are running, and that one of them is waiting for an answer.
    ///
    /// The count is the badge rather than the label because "how many" is the question you have
    /// while looking at it from here, and a number at the corner answers it without a tap. A dot
    /// with nothing running says none of this and looks the same as a dot that is about to open
    /// an empty panel, which is what it used to be.
    var terminalDot: some View {
        let running = model.terminals.filter(\.isRunning).count
        let wantsAttention = model.terminals.contains { $0.attention != nil }
        return sessionDot(
            symbol: running > 0 ? "terminal.fill" : "terminal",
            label: running > 0 ? "Mac terminals, \(running) running" : "Open Mac terminals",
            enabled: true,
            tint: wantsAttention ? .orange : (running > 0 ? ColorPalette.ink : nil),
            badge: running > 0 ? running : nil,
            badgeTint: wantsAttention ? .orange : ColorPalette.accent
        ) {
            showsTerminals = true
        }
    }

    func sessionDot(
        symbol: String,
        label: String,
        enabled: Bool,
        tint: Color? = nil,
        badge: Int? = nil,
        badgeTint: Color = ColorPalette.accent,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint ?? ColorPalette.ink)
                .frame(width: 48, height: 48)
                // Plain glass, with the press answered by the button style instead.
                //
                // This is not the fix for the taps these dots were swallowing — that was the
                // badge, drawn outside the button's bounds and therefore its own hit region,
                // which is why it is now `allowsHitTesting(false)`. The interactive glass is
                // fine in a button; the clipboard row uses it in buttons that work. Plain is
                // chosen here only so that one press gets one answer rather than two.
                .glassSurface(in: Circle())
                .opacity(enabled ? 1 : 0.4)
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Text("\(badge)")
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(ColorPalette.onInk)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 15, minHeight: 15)
                            .background(badgeTint, in: Capsule())
                            // Tucked inside the circle rather than hung off its corner. It
                            // used to sit four points outside the button's bounds, which made
                            // the badge the nearest thing to a thumb coming from that side —
                            // and a tap that landed on the number did nothing at all.
                            .offset(x: -1, y: 1)
                            .allowsHitTesting(false)
                    }
                }
        }
        // A square hit area rather than the circle that is drawn. A circle's corners are the
        // parts a thumb misses, and this is a one-glyph target beside the pill's edge — the one
        // control on the screen with nothing around it to catch a near miss.
        .contentShape(Rectangle())
        .buttonStyle(RailButtonStyle(scale: 0.92))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    var connectionPathChip: some View {
        Text(connectionPathTitle)
            // Its own voice, because it is the one thing in the row that is a readout rather than
            // a control: small, tracked and bold reads as a label at a glance, and nothing about
            // it invites a press.
            .font(.caption2.weight(.bold))
            .tracking(0.5)
            .pillChip()
            .accessibilityLabel("Connection path, \(connectionPathTitle)")
    }

    /// The connection path, and — when they are different — the path the picture is taking.
    ///
    /// Two facts in one chip, with the second appearing only when it is interesting. On a LAN or a
    /// typed-in address the picture already goes straight to the Mac, so `DIRECT·P2P` would be two
    /// spellings of one thing; on the relay the two are genuinely different paths, and the suffix is
    /// the whole answer to whether the session punched through.
    ///
    /// Read from ``SessionModel/usedDirectPath`` and not from the path above it, because those are
    /// different questions: a session that punched is still relayed — the relay splices its control
    /// connection and still meters it — and it is the *picture* that went around.
    private var connectionPathTitle: String {
        let connection = model.connectionPath?.rawValue ?? "None"
        guard model.usedDirectPath, model.connectionPath == .relay else { return connection }
        return "\(connection)·P2P"
    }

    /// The stream quality, as a chip that opens the presets.
    ///
    /// It was four segments side by side — about a hundred and forty points of a row that also
    /// has to hold the path, the fit, the camera and the quality. On a portrait phone that is
    /// more than the pill has room for, and the row paid for it by pushing the terminal dot off
    /// the screen entirely. Then it was a chip that cycled through them on tap, which fit but
    /// said nothing: one word that changes when touched, with no way to see what else there was
    /// or that there was anything else at all.
    ///
    /// A menu is the shape that keeps both. The chip is as small as the cycling one, and tapping
    /// it shows all four with the bitrate beside each — which is the part that was missing. "Low"
    /// and "Med" mean nothing without knowing what is being given up to get them.
    var qualityChip: some View {
        Menu {
            ForEach(SessionModel.StreamQuality.allCases, id: \.self) { preset in
                Button {
                    withAnimation(Motion.settle) { model.setStreamQuality(preset) }
                } label: {
                    if preset == model.streamQuality {
                        Label(preset.menuTitle, systemImage: "checkmark")
                    } else {
                        Text(preset.menuTitle)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "speedometer")
                Text(model.streamQuality.chipTitle)
                    .monospacedDigit()
            }
            .pillChip()
        }
        .buttonStyle(RailButtonStyle(scale: 0.9))
        .menuInk()
        .accessibilityLabel("Stream quality")
        .accessibilityValue(model.streamQuality.chipTitle)
    }



    /// Whether the Mac's sound comes out of this phone.
    ///
    /// **The control the preference's own comment has claimed since it was written.** It says the
    /// switch is "one tap away, in the session panel, under Stream" — and there was no such
    /// control. The only one was in Settings, and Settings cannot be opened while a session is
    /// running, which is the only moment anybody wants to silence a Mac: the sound is the Mac
    /// talking back, and it is noticed mid-session or not at all. So the switch existed, worked,
    /// and was unreachable from the one place it was described.
    ///
    /// An icon rather than a word. This row already carries the path, the quality and the fit,
    /// and it is the row whose last growth pushed the terminal dot off the screen entirely — a
    /// fourth word would be that again. The glyph says it on its own, and the two states are as
    /// far apart as a speaker with waves and a speaker with a stroke through it.
    ///
    /// Gated like every other paid control, and drawn as itself when it is: the Mac's sound is on
    /// Relay and above, and hiding the control would hide the reason to move up a rung.
    var soundButton: some View {
        PlanLocked(
            capability: .macSound,
            title: "Sound from the Mac",
            diameter: 26,
            isIncluded: model.storeManager.access.includes(.macSound)
        ) {
            Button {
                withAnimation(Motion.settle) { model.hostAudioMuted.toggle() }
            } label: {
                Image(systemName: model.hostAudioMuted ? "speaker.slash" : "speaker.wave.2")
                    .pillChip()
            }
            .buttonStyle(RailButtonStyle(scale: 0.9))
            .menuInk()
            .accessibilityLabel(model.hostAudioMuted ? "Unmute the Mac" : "Mute the Mac")
        }
    }

    /// How the picture fits the screen — a menu, because "Fit" and "Fill" are not a sentence.
    ///
    /// The chip was a toggle between two words, and two words are all it had room for: a Mac's
    /// screen is wider than a phone's, so one choice shows all of it with bars at the sides and
    /// the other shows a full screen with the edges cut off. Neither word says which is which,
    /// and nothing on screen did either. The menu says both in full, and marks the one that is on.
    var fillChip: some View {
        Menu {
            Button { setFill(false) } label: {
                if !scalesToFill { Label("Fit the whole screen", systemImage: "checkmark") }
                else { Text("Fit the whole screen") }
            }
            Button { setFill(true) } label: {
                if scalesToFill { Label("Fill the phone screen", systemImage: "checkmark") }
                else { Text("Fill the phone screen") }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: scalesToFill
                      ? "arrow.up.left.and.arrow.down.right"
                      : "arrow.down.right.and.arrow.up.left")
                Text(scalesToFill ? "Fill" : "Fit")
                    .monospacedDigit()
            }
            .pillChip(selected: scalesToFill)
        }
        .buttonStyle(RailButtonStyle(scale: 0.9))
        .menuInk()
        .accessibilityLabel("How the picture fits the screen")
        .accessibilityValue(scalesToFill ? "Filling the phone screen" : "Fitting the whole screen")
        .fixedSize(horizontal: true, vertical: false)
    }

    /// One place that knows what changing this costs, because the menu gives it two ways to
    /// happen and there is only one right way to do it.
    func setFill(_ filled: Bool) {
        withAnimation(Motion.settle) {
            scalesToFill = filled
            // The pan belongs to the old scale: a picture that was panned to the edge of a
            // fitted frame is off-screen the moment it grows to fill.
            pan = .zero
        }
    }

    func expandStatusBar() {
        withAnimation(Motion.morph) {
            statusBarExpanded = true
        }
        // Held, so a manual collapse cancels the timer rather than racing it: without this the
        // pending collapse fires anyway a moment later, and a deliberate expand that is closed
        // by hand would spring shut again on its own.
        statusBarCollapseTask?.cancel()
        statusBarCollapseTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            collapseStatusBar()
        }
    }

    func collapseStatusBar() {
        statusBarCollapseTask?.cancel()
        statusBarCollapseTask = nil
        withAnimation(Motion.morph) {
            statusBarExpanded = false
        }
    }

}

/// The one surface the pill's option row is built from.
///
/// Four controls stand in that row and they had four appearances between them: two materials, two
/// paddings, two glyph sizes, and a camera button that looked like a different kind of object from
/// the chips beside it. A row of things that are all buttons has to look like one kind of thing —
/// left to differ, the difference reads as meaning, and the eye learns that the camera is
/// pressable and the quality is a label, which is backwards.
///
/// A flat fill rather than a material: the row already sits inside the pill's glass, and a second
/// frosted layer within it is two answers to "what is this sitting on".
///
/// `selected` is the app's one accent, and here it means what it means everywhere else — this one
/// is on.
extension View {
    func pillChip(selected: Bool = false) -> some View {
        self
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(selected ? ColorPalette.ink : Color.secondary)
            // Seven rather than nine: the merged row carries six items on a portrait phone,
            // and two points off each side of four chips is most of what it needed.
            .padding(.horizontal, 7)
            .frame(height: 28)
            .background(
                selected
                    ? AnyShapeStyle(ColorPalette.selectedFill)
                    : AnyShapeStyle(.primary.opacity(0.08)),
                in: Capsule()
            )
    }
}
