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

    /// The bar: a status pill, four buttons floating around it, and a panel behind the pill's face.
    ///
    /// **Both halves of what a session needs, in the two places they belong.** While watching, the
    /// four things somebody reaches for are on the bar itself as circles with no words: they are
    /// pressed with the picture in front of the user, and a glyph is enough for a control that is
    /// pressed without being read. Everything else is inside the pill, which opens into rows of
    /// chips that say what they do, a control that can be read rather than recognised.
    ///
    /// The four stand down while the panel is open: it holds the same actions with their words on,
    /// and it wants the width.
    var statusBar: some View {
        // One circle leading and two trailing, so the strip is balanced around the thing it is
        // reporting on.
        HStack(alignment: .center, spacing: 5) {
            // The lock, which is the one that acts on the Mac itself. The way back to the picker
            // led this row until it stopped earning its circle: it is a labelled chip inside the
            // pill, beside the other things done to the session, and a second door to the same
            // room is 48 points of chrome taken off the picture to say nothing the pill does not
            // say with a word on it.
            if !statusBarExpanded {
                lockDot.layoutPriority(1)
            }
            statusPill
            // The two about the picture, nearest the thing the picture is reported in.
            if !statusBarExpanded {
                mosaicDot.layoutPriority(1)
                terminalDot.layoutPriority(1)
            }
        }
        // The closed bar's own width, taken while it is closed: the panel opens into this much and
        // no less, which is what makes the pill swallow the circles' space rather than the bar
        // shrinking by it as they go.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            guard !statusBarExpanded else { return }
            collapsedBarWidth = width
        }
        // **The one animation on this bar, and it is for what the pill holds.** The way into an
        // arrangement and the window count come and go with the picture, and the pill's contents
        // are a `VStack` whose height follows them: without this its rows would jump in the frame
        // the picture changes, which reads as the screen flinching at the exact moment the picture
        // does something else.
        //
        // Keyed on the one condition, so nothing else about the bar is animated by it: the pill's
        // own opening has its own spring, and a second one here would fight it.
        .animation(Motion.settle, value: model.canReturnToMosaic)
        // Narrower than the rails' own inset, on purpose: every point taken off the sides is a
        // point the pill's rows get, and the pill is the one piece of chrome that has to hold
        // several rows of other things.
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
                // Ten between the rows and six between the chips inside one: a row is a subject and
                // its buttons, and the gaps have to say which is which.
                VStack(alignment: .leading, spacing: 10) {
                    // ── Row 1: who, and which path the picture is taking ────────────
                    //
                    // The name has this row to itself, which it did not before. It used to share
                    // with the clock, the latency and the quit button, and the arithmetic never
                    // worked on a phone held upright: "Damian's MacBook Pro" is the longest
                    // string in the pill by twice over, and the row could only fit it by
                    // clipping it. The readouts moved down, where they belong anyway: the path
                    // describes the stream, and the stream's name is on the row above.
                    HStack(spacing: 8) {
                        // Green once the session is up rather than merely connected: a socket
                        // that is open but still handshaking is not something to reassure
                        // anyone about, and the phase is the only thing that knows the
                        // difference. The same dot as the closed pill's, so the two faces of it
                        // cannot disagree about whether the Mac is there.
                        Circle()
                            .fill(isReconnectingToMac ? ColorPalette.caution : (model.phase == .ready ? Color.green : ColorPalette.ink))
                            .frame(width: 7, height: 7)
                        Text(model.hostName ?? "Mac")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        // **The path, and the name yields to it.** The row used to end in a power
                        // chip and a red QUIT capsule, and the price of both was the name: "Damian's
                        // MacBook Pro" came out as "Damia…", on the one line whose job is to say
                        // which Mac this is. The path is a fixed width, so it is the name that gives
                        // way here, which is the one thing on this row that can be shortened without
                        // losing a fact.
                        //
                        // No figure with it. The latency was a millisecond count and then a word,
                        // and both are gone: this panel reports whether the session is working, and
                        // the dot on the closed pill is the whole of that answer. Somebody who wants
                        // the number to the millisecond has the Sessions tab, which is where a
                        // figure that is being *studied* belongs, rather than a header somebody is
                        // reading while they look at their Mac.
                        Spacer(minLength: 8)
                        connectionPathChip
                    }

                    // ── Row 2: the controls that act on the picture in front of you ─
                    //
                    // **Labelled like the rows below it, because it is one of them.** The panel is
                    // four rows of one shape: a subject in the column on the left, and the buttons
                    // that act on it in the slots beside. This row is what gets pressed *while
                    // watching*: the sound from the Mac, and the three things about the picture.
                    // Quality is not one of them any more. It is a setting, it was a gauge glyph with
                    // a menu behind it, and both this panel and the session's own Settings hold it
                    // with a name on it.
                    actionRow("Stream", systemImage: "play.rectangle") {
                        soundButton
                        fillChip
                        if zoom > 1.01 {
                            Button {
                                // The same reset the screen does for itself when the source
                                // changes, from the one definition of where the picture rests.
                                resetPicture()
                            } label: {
                                Text("\(Int((zoom * 100).rounded()))%")
                                    .monospacedDigit()
                                    .pillChip(filling: true)
                            }
                            .buttonStyle(RailButtonStyle(scale: 0.9))
                        }
                        Button { ScreenshotShare.present() } label: {
                            Image(systemName: "camera")
                                .pillChip(filling: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Take screenshot")
                        // The controls themselves, put away. On this row rather than among the
                        // session's own chips, because what it acts on is the picture in front of
                        // the user: the same subject the zoom, the fill and the camera belong to.
                        actionChip(
                            "Immersive",
                            systemImage: "arrow.up.left.and.arrow.down.right"
                        ) {
                            enterImmersive()
                        }
                    }

                    // ── What can be done, sorted by what it is done to ─────────────
                    //
                    // **Three subjects, in the app's own section label, and chips beside each.** The
                    // split is the one this panel turns on: the stream is the picture in front of the
                    // user, the Mac is the machine at the other end, and the session is this
                    // connection to it. Locking a Mac and darkening its displays are things done to
                    // that machine whether or not anybody is watching; going back to the picker,
                    // opening a shell and returning to an arrangement are all about the connection
                    // the user is sitting in.
                    //
                    // Chips rather than rows: they keep the compactness of the dots that were here
                    // before and the words of the rows that replaced them.
                    actionRow("Mac", systemImage: "macbook") {
                        actionChip("Lock", systemImage: "lock.fill") { model.lockMac() }
                        actionChip(
                            model.privacyModeEnabled ? "Restore" : "Darken",
                            systemImage: model.privacyModeEnabled ? "sun.max" : "sun.min"
                        ) {
                            model.setPrivacyMode(!model.privacyModeEnabled)
                        }
                    }

                    actionRow("Session", systemImage: "antenna.radiowaves.left.and.right") {
                        // **The way back to the picker, with the Mac left connected.** This screen
                        // used to have one way out and it was Quit, so looking at the list of Macs
                        // meant ending the session, and the session somebody was paying for went
                        // with it. The same act as the picker's own row for this Mac, approached
                        // from the other side. See ``SessionModel/stepAwayFromSession()``.
                        actionChip("Connect", systemImage: "macbook.and.iphone") {
                            model.stepAwayFromSession()
                        }
                        actionChip(
                            "Terminal",
                            // The same two facts the dot beside the pill reads: a shell running
                            // at all fills the glyph, and one waiting for an answer goes orange.
                            systemImage: terminalRunning > 0 ? "terminal.fill" : "terminal",
                            tint: terminalWantsAttention ? .orange : nil
                        ) {
                            showsTerminals = true
                        }
                        if model.canReturnToMosaic {
                            actionChip(
                                "Mosaic",
                                systemImage: "rectangle.split.2x2",
                                tint: ColorPalette.accent
                            ) {
                                animateBackToMosaic()
                            }
                        }
                    }

                    // A row like the three above it, and the only one whose subject is the end of
                    // something. Filled red rather than merely written in it: this is the one control
                    // in the panel that cannot be taken back by pressing it again.
                    actionRow("End", systemImage: "power") {
                        actionChip("Quit", isDestructive: true) { model.disconnect() }
                    }
                }
                // Wider on the right than the left. What ends on that side is a control — the
                // camera, the last chip — and a control flush against the glass reads as clipped;
                // what ends on the left is a label, which is happy at the edge.
                .padding(.leading, 16)
                .padding(.trailing, 20)
                // The rows' own gap at the two ends of the stack, so the first and last of them are
                // inset by what separates them rather than by less.
                .padding(.vertical, 10)
                // **The width of the bar it came out of, exactly.** That is where the horizontal
                // half of the opening comes from: the closed bar is the pill plus the circles
                // around it, and the panel replaces both, so it opens into their space and grows
                // sideways as it grows down. Fixed rather than a floor, because the rows inside are divided to fill
                // it: a panel that could also grow to fit its rows would leave whichever rows were
                // narrower than the widest one ending short of the glass.
                //
                // Until the bar has been measured once, which the guard on the measurement sees to
                // when the panel opens before the session's own auto-collapse, the panel is as wide
                // as its own rows.
                .frame(width: collapsedBarWidth > 0 ? collapsedBarWidth : nil, alignment: .leading)
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
                    // Two lines, where this was one running line of everything at once.
                    //
                    // The source's name is a whole sentence — "Built-in Retina Display" is
                    // seventeen characters of it — and it was being asked to share a single row
                    // with the Mac's name, the path and the frame rate. What that produced was
                    // four things competing for a line and the longest one losing. So the line is
                    // split by what it is about: who it is answers "is this working" and belongs
                    // on the first line, and what is being shown and over which path answers
                    // "what am I looking at" and goes under it.
                    //
                    // The dot is part of the name's line rather than a mark floating beside the
                    // block. Centred against both lines it sat between them with a gap either
                    // side, which reads as a dot that lost its label — and the label is the Mac
                    // it is reporting on.
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 7) {
                            // **The pill's whole report on whether the session is working.**
                            //
                            // Green when the Mac is connected and sending, red when it is
                            // connected and has stopped. It was white, which said nothing: a dot
                            // that is always the same colour is decoration.
                            //
                            // Green rather than the palette's white because the host picker
                            // already spends green on "this Mac is reachable", and a second
                            // colour for the same fact would be two vocabularies for one thing.
                            //
                            // A latency figure used to sit after the name — a number first, then
                            // a word — and both are gone. This is the one line in the app that is
                            // read without being asked for, and a figure here reads as a warning
                            // even at 90 ms, which frightens people into closing a session they
                            // did not need to close. What the pill has to answer is whether the
                            // Mac is there, and the dot is that answer.
                            //
                            // The figure is not lost. The session's Settings panel reports it
                            // twice — the control channel's own round trip, and the path's, the
                            // second labelled direct or relay — which is a screen somebody opens
                            // on purpose rather than a header they glance at.
                            Circle()
                                .fill(connectionDotTint)
                                .frame(width: 6, height: 6)
                                .accessibilityLabel(connectionDotLabel)
                            Text(model.hostName ?? "Mac")
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                        }

                        HStack(spacing: 6) {
                            // **What the Mac is doing, in the place what it is showing used to be.**
                            // A Mac being put back has no source to name and no frames to describe,
                            // and this line is where the user looks to find out why the picture has
                            // stopped: leaving the last window's title up described a session that
                            // was no longer there.
                            if isReconnectingToMac {
                                Text("Reconnecting…")
                                    .font(.caption2)
                                    .foregroundStyle(ColorPalette.caution)
                                    .lineLimit(1)
                            } else if let sourceTitle = model.activeSourceTitle {
                                Text(sourceTitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    // **The name yields, and the control does not.** This row is
                                    // a window's title and then the controls that act on it, and
                                    // a window's title is unbounded — the one on this Mac is 74
                                    // characters of a terminal's own status line. Laid out as
                                    // equals, that title took the row and squeezed the way back
                                    // out of the mosaic to nothing, which is a control that
                                    // exists in the code and nowhere on the screen.
                                    .layoutPriority(0)
                            }
                            // **What the window is one of, while it is one of several.** A window
                            // opened out of an arrangement leaves the arrangement behind it, and the
                            // row that goes back to it is one tap down: nothing *on* the collapsed
                            // pill said there was anything to go back to. This says it in the app's
                            // own word — the same "N windows" a mosaic is named with — and the way
                            // back is then a row with the same name rather than a symbol to be
                            // discovered. See ``MacSession/canReturnToMosaic``.
                            if model.canReturnToMosaic, model.mosaicChoicesList.count > 1 {
                                Text("in \(model.mosaicChoicesList.count) windows")
                                    .font(.caption2.weight(.bold))
                                    .tracking(0.5)
                                    .foregroundStyle(.secondary)
                                    .pillChip()
                                    .accessibilityLabel(
                                        "One of \(model.mosaicChoicesList.count) windows in a mosaic"
                                    )
                            }
                            connectionPathChip
                        }
                        // Under the Mac's name rather than under the dot, which is what makes the
                        // second line read as a continuation of the first.
                        .padding(.leading, 13)
                    }

                    // **The one thing that says the pill is a control.** What is left on the closed
                    // face is a report, and a report does not invite a press: every action the
                    // session has is either floating beside the pill or inside it. This is the
                    // app's own mark for "leads somewhere", pointing down because that is the way
                    // the panel opens.
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
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




    /// Whether the Mac on screen is being put back: a drop the ladder is retrying, or the resume that
    /// follows the app being killed in the background.
    ///
    /// **The one state the pill could not tell the truth about.** Its dot answers whether the picture
    /// is arriving, which is green or red, and a Mac being reconnected to is neither: the frames
    /// stopping is the whole reason the retry exists, so a red dot read as "this is over" while the
    /// app was still working on it.
    ///
    /// Read from the session, which is where the two flags that answer it can be told apart. The
    /// first version of this asked ``SessionModel/isResuming`` directly and was wrong for exactly the
    /// case it was written for: that flag is cleared on the first phase that holds a session, which
    /// a dial is, so a Mac being put back read as one being opened from the second it started.
    var isReconnectingToMac: Bool { model.isBeingPutBack }

    /// The dot's colour, in the one place both faces of the pill read it from.
    ///
    /// Amber for a Mac being put back, and it is the palette's caution rather than a second red: a
    /// reconnection is a state the app is working on, not a failure. Green while the picture is
    /// arriving and red once it has stopped, which are the two answers the dot had before.
    var connectionDotTint: Color {
        if isReconnectingToMac { return ColorPalette.caution }
        return model.isVideoStreaming ? .green : .red
    }

    var connectionDotLabel: String {
        if isReconnectingToMac { return "Reconnecting to the Mac" }
        return model.isVideoStreaming ? "Connected" : "Not streaming"
    }

    var connectionPathChip: some View {
        Text(connectionPathTitle)
            // Its own voice, because it is the one thing in the row that is a readout rather than
            // a control: small, tracked, bold and grey reads as a label at a glance, and nothing
            // about it invites a press.
            .font(.caption2.weight(.bold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
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

    /// One of the session's actions, as a chip: a glyph, a word or two, and what pressing it does.
    ///
    /// **Short words on purpose.** The row divides its width between its chips, so a long label does
    /// not push its neighbours around, it takes width from them: "Darken" and a sun says what
    /// "Darken the Mac's displays" says, and the Settings screen holds the long form.
    ///
    /// Filling, because the chip is placed in a slot rather than sized to its words. See
    /// ``ChipSlots``. The glyph is optional for the one chip whose subject is already named by the
    /// label on its left, which keeps the power symbol from appearing twice in the same row.
    func actionChip(
        _ label: String,
        systemImage: String? = nil,
        isDestructive: Bool = false,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(label)
                    .lineLimit(1)
            }
            .foregroundStyle(tint ?? (isDestructive ? ColorPalette.onInk : ColorPalette.ink))
            .pillChip(filling: true, destructive: isDestructive)
        }
        .buttonStyle(RailButtonStyle(scale: 0.94))
    }

    /// Wide enough for "Session" with its glyph, so that both groups' chips start on one line.
    static let actionLabelWidth: CGFloat = 74

    /// A group of the session's actions: what they are done to, and the chips themselves beside it.
    ///
    /// **Beside the chips rather than above them.** Above, a label cost a row per group and left
    /// every row ending wherever its longest chip happened to end; beside them the panel is a
    /// column of labels and a column of chips, which is the shape these same labels take in
    /// Settings. The fixed width is what makes the two columns line up.
    func actionRow<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Controls.sectionLabel(title, systemImage: systemImage)
                .frame(width: Self.actionLabelWidth, alignment: .leading)
                // Against the first row of chips rather than the top of their capsules: a 28pt chip
                // centres its own 12pt line, which is seven points down.
                .padding(.top, 7)
            ChipSlots { content() }
        }
    }

    /// Lock, and the displays, in one button: a tap locks, a hold offers both.
    ///
    /// The two are the same act at different strengths, and the icon says which one is on: a shield
    /// while the displays are darkened, which is otherwise invisible from here.
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

    /// The way back into an arrangement, for as long as one of its tiles is the picture.
    ///
    /// Drawn only while the picture is one tile of a standing arrangement, see
    /// ``SessionModel/canReturnToMosaic``: a button that was always there would go nowhere for the
    /// whole of a session on a single window. Tinted with the accent rather than the ink the other
    /// three use, for the one reason the accent exists: this is not a tool, it is a state the user
    /// is in.
    @ViewBuilder
    var mosaicDot: some View {
        if model.canReturnToMosaic {
            sessionDot(
                symbol: "rectangle.split.2x2",
                label: "Back to the mosaic",
                tint: ColorPalette.accent
            ) {
                // **The window shrinks into the tile it is about to hold.** The picture is asked
                // for at the end of that movement rather than here, so the canvas arrives around
                // a window that is already where it belongs; the borders come back with it and
                // fade in over the picture they describe. See ``mosaicOverlay``.
                animateBackToMosaic()
            }
            .transition(.scale.combined(with: .opacity))
        }
    }

    /// The terminal, and the two things about it worth knowing from the session screen: that shells
    /// are running, and that one of them is waiting for an answer.
    ///
    /// The count is the badge rather than the words because "how many" is the question you have
    /// while looking at it from here, and a number at the corner answers it without a tap. A glyph
    /// with nothing running says none of this and looks the same as one about to open an empty
    /// panel, which is what it used to be.
    var terminalDot: some View {
        sessionDot(
            symbol: terminalRunning > 0 ? "terminal.fill" : "terminal",
            label: terminalRunning > 0
                ? "Mac terminals, \(terminalRunning) running"
                : "Open Mac terminals",
            tint: terminalWantsAttention ? .orange : nil,
            badge: terminalRunning > 0 ? terminalRunning : nil,
            badgeTint: terminalWantsAttention ? .orange : ColorPalette.accent
        ) {
            showsTerminals = true
        }
    }

    /// One of the bar's floating buttons: a glyph in a circle of glass.
    func sessionDot(
        symbol: String,
        label: String,
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
                // Plain glass, with the press answered by the button style instead, so that one
                // press gets one answer rather than two.
                .glassSurface(in: Circle())
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Text("\(badge)")
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(ColorPalette.onInk)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 15, minHeight: 15)
                            .background(badgeTint, in: Capsule())
                            // Tucked inside the circle rather than hung off its corner. It used to
                            // sit four points outside the button's bounds, which made the badge the
                            // nearest thing to a thumb coming from that side, and it is its own hit
                            // region, so a tap that landed on the number did nothing at all.
                            .offset(x: -1, y: 1)
                            .allowsHitTesting(false)
                    }
                }
        }
        // A square hit area rather than the circle that is drawn. A circle's corners are the
        // parts a thumb misses, and this is a one-glyph target beside the pill's edge, with
        // nothing around it to catch a near miss.
        .contentShape(Rectangle())
        .buttonStyle(RailButtonStyle(scale: 0.92))
        .accessibilityLabel(label)
    }

    /// The two facts the terminal's button is drawn from.
    ///
    /// "How many" is the badge's business. These are what decide the glyph and the tint: whether a
    /// shell is running at all, and whether one of them wants an answer.
    private var terminalRunning: Int { model.terminals.filter(\.isRunning).count }
    private var terminalWantsAttention: Bool { model.terminals.contains { $0.attention != nil } }

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
                    .pillChip(filling: true)
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
                if scalesToFill { Label("Fill this screen", systemImage: "checkmark") }
                else { Text("Fill this screen") }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: scalesToFill
                      ? "arrow.up.left.and.arrow.down.right"
                      : "arrow.down.right.and.arrow.up.left")
                Text(scalesToFill ? "Fill" : "Fit")
                    .monospacedDigit()
            }
            .pillChip(selected: scalesToFill, filling: true)
        }
        .buttonStyle(RailButtonStyle(scale: 0.9))
        .menuInk()
        .accessibilityLabel("How the picture fits the screen")
        .accessibilityValue(scalesToFill ? "Filling this screen" : "Fitting the whole screen")
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

/// The one surface the pill's buttons are built from.
///
/// A flat fill rather than a material: the chips sit inside the pill's own glass, and a second
/// frosted layer within it is two answers to "what is this sitting on".
///
/// The words are the caller's colour, and in this bar that is the ink. `selected` overrides it with
/// the app's one accent, meaning here what it means everywhere else, this one is on; `destructive`
/// is the single filled red, carrying the palette's `onInk` because that is what reads on its own
/// colour.
extension View {
    @ViewBuilder
    func pillChip(
        selected: Bool = false,
        filling: Bool = false,
        destructive: Bool = false
    ) -> some View {
        let chip = self
            .font(.system(size: 12, weight: .medium))
            // Seven rather than nine: the merged row carries six items on a portrait phone,
            // and two points off each side of four chips is most of what it needed.
            .padding(.horizontal, 7)
            .frame(height: 28)
            // For the chips that share a row with others: the row cuts its width into equal
            // slots, and a chip is as wide as its slot rather than as wide as its own words.
            .frame(maxWidth: filling ? .infinity : nil)

        // **The plain chip's colour is the caller's.** It used to be the secondary grey here, which
        // was right while these were readouts and wrong once they were the panel's buttons: a row of
        // controls drawn in the same grey as the labels beside it reads as a row that is switched
        // off. A readout says so for itself now, and a caller's own tint reaches the chip.
        if destructive {
            chip
                // A filled chip carries the ink that reads on its own colour: the palette pairs
                // every fill with one, and white on the red would be the pair nobody can read.
                .foregroundStyle(ColorPalette.onInk)
                .background(ColorPalette.danger, in: Capsule())
        } else if selected {
            chip
                .foregroundStyle(ColorPalette.ink)
                .background(ColorPalette.selectedFill, in: Capsule())
        } else {
            chip.background(.primary.opacity(0.08), in: Capsule())
        }
    }
}

/// Chips that divide the width they are given between them, equally.
///
/// **What it replaces was a flow, and a flow was the wrong shape for this.** It gave every chip the
/// width its own words needed, which is right in a paragraph and wrong in a row of buttons: a row of
/// two chips ended well short of a row of three, so the panel had a ragged right edge and a column
/// of empty glass beside the shorter rows, and no two buttons in it were the same size. Cut into
/// equal slots instead, every row ends where the panel does and every button is the size of its
/// neighbours. What a chip cannot do, then, is be as wide as its words: the words are chosen to fit
/// the slot, and the ones that do not fit are the labels the Settings screen holds in full.
private struct ChipSlots: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let count = subviews.count
        guard count > 0 else { return .zero }
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        guard let width = proposal.width else {
            let natural = subviews.reduce(CGFloat.zero) { $0 + $1.sizeThatFits(.unspecified).width }
            return CGSize(width: natural + spacing * CGFloat(count - 1), height: height)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let count = CGFloat(subviews.count)
        guard count > 0 else { return }
        let slot = (bounds.width - spacing * (count - 1)) / count
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + (slot + spacing) * CGFloat(index), y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: slot, height: bounds.height)
            )
        }
    }
}
