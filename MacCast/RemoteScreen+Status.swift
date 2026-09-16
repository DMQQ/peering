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
        HStack(alignment: .center, spacing: 7) {
            // The dots are served first and the pill takes what is left. The pill was taking
            // the width it wanted, which on a portrait phone pushed the terminal dot off the
            // edge of the screen — and of the three, the dots are the ones with nowhere to
            // compress to, being circles with one glyph in them.
            audioDot.layoutPriority(1)
            statusPill
            terminalDot.layoutPriority(1)
        }
        .padding(.horizontal, 10)
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
                VStack(alignment: .leading, spacing: 6) {
                    // ── Row 1: identity + clock + quit ──────────────────────────────
                    HStack(spacing: 10) {
                        // Green once the session is up rather than merely connected: a socket
                        // that is open but still handshaking is not something to reassure
                        // anyone about, and the phase is the only thing that knows the
                        // difference.
                        Circle()
                            .fill(model.phase == .ready ? Color.green : ColorPalette.ink)
                            .frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            // The one thing in this row that gives way. It is the longest string
                            // in it and the only one whose meaning survives being cut — "Damian's
                            // Ma…" is still the Mac, where a clipped "156 m" is not a
                            // measurement. Both the readouts beside it are fixed so that they
                            // cannot be the ones squeezed, which is how the latency ended up
                            // rendering one digit per line down the side of the pill.
                            Text(model.hostName ?? "Mac")
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text(model.videoStatus)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        // No `Spacer` here, and that is the whole of why the pill is the width it
                        // is. A spacer takes up any slack in the row, so the row asked for as
                        // much width as the layout would give it — which in landscape meant the
                        // pill stretched most of the way across the screen to hold four short
                        // readouts. Without one the row is exactly as wide as its contents and
                        // the pill hugs them.
                        sessionClock
                        if let latency = model.latencyMilliseconds {
                            Text("\(Int(latency.rounded())) ms")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(ColorPalette.reading(latency))
                                .fixedSize()
                        }
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

                    // ── Row 2: quality + view options ────────────────────────────────
                    HStack(spacing: 8) {
                        connectionPathChip
                        qualityChip
                        fillChip
                        // The audio switch moved out to the dot beside the pill — see
                        // `audioDot`. It was a chip here and it is a state you reach for
                        // mid-session, which is the same case the dots exist for; this row has
                        // the camera and the zoom to spend its width on.
                        if zoom > 1.01 {
                            Button {
                                zoom = 1; pan = .zero
                            } label: {
                                Text("\(Int((zoom * 100).rounded()))%")
                                    .font(.caption.monospacedDigit())
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(.ultraThinMaterial).clipShape(Capsule())
                            }.buttonStyle(.plain)
                        }
                        Button { ScreenshotShare.present() } label: {
                            Image(systemName: "camera")
                                .font(.system(size: 13))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Take screenshot")
                    }

                    // Its own row, and unbounded in both directions. What this carries is an
                    // error string from AVKit, and a *truncated* one is worth almost nothing —
                    // "Could not start: Failed to start pictu…" names neither the fault nor the
                    // reason. Set apart from the row above because it is a diagnostic, not a
                    // control: it takes whatever width it needs and wraps to whatever height.
                    if let attempt = SessionPiP.shared.lastAttempt {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pic-in-pic: \(attempt)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            if let why = SessionPiP.shared.lastRefusal {
                                Text(why)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
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
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            // Green when the Mac is connected and sending, red when it is connected
                            // and has stopped. It was white, which said nothing: a dot that is
                            // always the same colour is decoration, and this one sits in the pill
                            // that already carries the Mac's name and the latency — the two facts
                            // whose whole purpose is to be read at a glance.
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
                                // No spacer, for the reason Row 1 has none: the collapsed pill should be
                            // the width of what it says.
                            if let latency = model.latencyMilliseconds {
                                Text("\(Int(latency.rounded())) ms")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(ColorPalette.reading(latency))
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
                            if model.isVideoStreaming {
                                Text("\(Int(model.videoFramesPerSecond.rounded())) fps")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Video frame rate")
                                    .accessibilityValue("\(Int(model.videoFramesPerSecond.rounded())) frames per second")
                            }
                        }
                        // Aligned under the Mac's name rather than under the dot, which is what
                        // makes the second line read as a continuation of the first.
                        .padding(.leading, 14)
                    }
                }
                .padding(.horizontal, 12)
                // Two lines rather than one, and a fixed height for the same reason it was fixed
                // before: a pill that resized itself as a source changed would move the picture
                // under a finger that is aiming at it.
                .frame(height: 46)
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
        .glassEffect(.regular, in: pillShape)
    }

    /// What the two dots add to the pill's width: a dot and a gap on each side.
    static let sessionDotsWidth: CGFloat = (46 + 7) * 2

    /// How wide the pill itself is allowed to get.
    ///
    /// Wide enough that its two rows fit without wrapping: the Mac's name, the clock, the latency
    /// and the quit button on one line, and the path, the quality picker, the fill and the two
    /// tools on the next. At 420 the name wrapped onto two lines and pushed QUIT off its own —
    /// which is what "QUI / T" was. The cap is still a cap: on a wide landscape screen the pill
    /// stops growing rather than turning into a bar across the top of the picture.
    static let pillMaxWidth: CGFloat = 520

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
    /// The Mac's audio takes the slot, which is the same trade the pill's second row wanted: it
    /// is reached for mid-session, it has a state worth seeing at a glance, and it was a chip in
    /// a row that had run out of width.
    var audioDot: some View {
        sessionDot(
            symbol: model.hostAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            label: model.hostAudioMuted ? "Unmute the Mac" : "Mute the Mac",
            enabled: true,
            tint: model.hostAudioMuted ? Color.secondary : ColorPalette.ink
        ) {
            model.hostAudioMuted.toggle()
        }
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
            label: running > 0 ? "Mac terminals — \(running) running" : "Open Mac terminals",
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
                .frame(width: 46, height: 46)
                // Plain glass, with the press answered by the button style instead.
                //
                // This is not the fix for the taps these dots were swallowing — that was the
                // badge, drawn outside the button's bounds and therefore its own hit region,
                // which is why it is now `allowsHitTesting(false)`. The interactive glass is
                // fine in a button; the clipboard row uses it in buttons that work. Plain is
                // chosen here only so that one press gets one answer rather than two.
                .glassEffect(.regular, in: Circle())
                .opacity(enabled ? 1 : 0.4)
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Text("\(badge)")
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(ColorPalette.onInk)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 15, minHeight: 15)
                            .background(badgeTint, in: Capsule())
                            // Off the glass rather than on it, so the count reads as a mark on
                            // the button and not as part of what the button is drawing.
                            .offset(x: 4, y: -4)
                            // And out of the way of the press. Offset past the button's own
                            // bounds, the badge is its own hit region — so a tap that landed on
                            // the number was a tap on the badge, and the button underneath it
                            // did nothing.
                            .allowsHitTesting(false)
                    }
                }
        }
        .buttonStyle(RailButtonStyle(scale: 0.92))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    var connectionPathChip: some View {
        Text(model.connectionPath?.rawValue ?? "None")
            .font(.caption2.weight(.bold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.primary.opacity(0.08), in: Capsule())
            .accessibilityLabel("Connection path")
    }

    /// The stream quality, as one chip that moves on when tapped.
    ///
    /// It was four segments side by side — about a hundred and forty points of a row that also
    /// has to hold the path, the fit, the speaker, the camera and the quality. On a portrait
    /// phone that is more than the pill has room for, and the row paid for it by pushing the
    /// terminal dot off the screen entirely. A chip showing the preset that is on, and moving to
    /// the next one when tapped, says the same thing in a fifth of the width — and it is the
    /// shape the mode button already uses, so the gesture is one this screen has taught.
    ///
    /// What it gives up is seeing all four at once. That is the trade: four options that fit are
    /// worth more than four options that push the controls off the edge.
    var qualityChip: some View {
        Button {
            let presets = SessionModel.StreamQuality.allCases
            let index = presets.firstIndex(of: model.streamQuality) ?? 0
            withAnimation(Motion.settle) {
                model.setStreamQuality(presets[(index + 1) % presets.count])
            }
        } label: {
            Text(model.streamQuality.rawValue)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
        .buttonStyle(RailButtonStyle(scale: 0.9))
        .accessibilityLabel("Stream quality")
        .accessibilityValue(model.streamQuality.rawValue)
        .accessibilityHint("Moves to the next preset")
    }


    /// How long the session has been up.
    ///
    /// `Text(_:style:.timer)` is a clock the render server owns rather than a view that redraws:
    /// it advances on its own, costs nothing per second, and stays correct while the app is
    /// suspended. A `Timer` here would be a wake-up a second, for a label.
    ///
    /// Absent rather than zero before a session exists — "0:00" against a Mac that is not
    /// connected would be measuring nothing at all.
    @ViewBuilder
    var sessionClock: some View {
        if let started = model.sessionStartedAt {
            Text(started, style: .timer)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                // One line, always. A timer counting up is all colons and digits, so a row short
                // of width wraps it a character at a time — which is how it ended up reporting
                // the session as a vertical column of numbers down the side of the pill.
                .fixedSize()
        }
    }

    /// Fitted or filled, named for the state it is in — like the mode button, and for the same
    /// reason: a control that advertises where it would go, while sitting in a state the user
    /// cannot read, is one whose meaning has to be remembered rather than seen.
    var fillChip: some View {
        Button {
            withAnimation(Motion.settle) {
                scalesToFill.toggle()
                // The pan belongs to the old scale: a picture that was panned to the edge of a
                // fitted frame is off-screen the moment it grows to fill.
                pan = .zero
            }
        } label: {
            Text(scalesToFill ? "Fill" : "Fit")
                .font(.caption.monospacedDigit())
                .foregroundStyle(scalesToFill ? ColorPalette.ink : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(scalesToFill ? ColorPalette.selectedFill : .clear, in: Capsule())
        }
        .buttonStyle(RailButtonStyle(scale: 0.9))
        .accessibilityLabel(scalesToFill ? "Filling the screen" : "Fitted to the screen")
        .fixedSize(horizontal: true, vertical: false)
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
