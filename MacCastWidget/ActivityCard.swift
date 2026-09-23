import SwiftUI

/// The one card both Live Activities are drawn from.
///
/// The Mac's card and the SSH one were written months apart and had drifted: two tile sizes, two
/// sets of paddings, the status on a line of its own in one and in a right-hand column in the
/// other, and a timer whose absence moved the End button up the card. They are the same object to
/// a reader, a session this phone is holding open which can be ended, so they are one shape here
/// and the two activities differ only in what they put in it.
///
/// The anatomy is the app's own row, one size up. A tile carrying the *kind* of session with a dot
/// for its state, the name over a line of status, and the reading and the way out at the trailing
/// edge. The kind is on the tile and the state is in the dot because the words already say the
/// state: an icon that changed with it as well was three tellings of one thing on a surface with
/// room for one.
struct ActivityCard: View {
    /// What the tile carries. A Mac session and a shell look different at a glance and the same
    /// shape otherwise.
    let symbol: String
    let tone: ActivityTone
    let name: String
    /// The state in words, with anything that counts folded in after it: "Connected via LAN",
    /// "Connected · 3 shells", "Connection dropped".
    ///
    /// One string rather than a status and a chip, and that is about which fact gives way first.
    /// Everything on this line has to fit in a third of a Lock Screen: given a chip of its own the
    /// count took its width from the state, and the state is the one thing on the card the user
    /// cannot get anywhere else. In a sentence it is the *tail* that truncates, so a long count on
    /// a narrow phone costs the count and nothing more.
    let status: String
    /// Nil until there is something to time. The system advances the clock from it, which is the
    /// only reason it keeps time on a screen where none of this app is running.
    var startedAt: Date?
    var action: ActivityCardAction?

    /// The tile, at the app's `IconTile` default size and with its own proportions.
    static let tile: CGFloat = 42
    static let tileCorner = tile * 0.286
    static let tileGlyph = tile * 0.405

    /// The width the clock is pinned to, at `.body` with monospaced digits.
    ///
    /// Seven glyphs, five of them digits at about ten points each and two colons: the longest
    /// reading a session reaches is `1:23:45`. A fixed box rather than a maximum, because what
    /// this is for is deciding where the text *ends*, not how much room it has.
    static let timerWidth: CGFloat = 68

    /// What the card is filled with, and what the ring around the state dot is drawn in.
    ///
    /// **One value rather than two that have to agree**, and heavy rather than light, for the
    /// reason `glassTint` is heavy in the app: this sits on a wallpaper that can be anything, and
    /// the card's own second line is `.secondary`, a colour that only reads as a caption over a
    /// dark ground. At 55% over a bright photo the status line was a grey ghost, which is the one
    /// line on the card that says what the session is doing.
    static let backgroundTint = Color.black.opacity(0.7)

    var body: some View {
        HStack(spacing: 12) {
            ActivityTile(symbol: symbol, tone: tone)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(name)
                        .font(.headline)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    // Nothing in the pending case, and the row does not move for it: the timer is
                    // on this line and the way out is on the one below, so a clock that has not
                    // started cannot take the End button with it.
                    if let startedAt {
                        Text(startedAt, style: .timer)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                            // **Two modifiers, and neither is decoration. A `.timer` ignores its
                            // frame's alignment.** It fills whatever width it is offered and draws
                            // its reading at the leading edge of it, so a `Spacer` pushes the clock
                            // nowhere and a trailing frame just leaves a gap the width of the
                            // unused box. The line alignment is the only thing that moves it, and
                            // the frame is what stops it taking the whole row from the name.
                            .multilineTextAlignment(.trailing)
                            .frame(width: ActivityCard.timerWidth, alignment: .trailing)
                    }
                }

                HStack(spacing: 8) {
                    Text(status)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    // **Not decoration, and its absence is the whole of a bug.** An `HStack` lays
                    // its children out from the leading edge and leaves the rest of the line empty,
                    // so without this the End capsule sat immediately after the status word: with a
                    // long status that is the middle of the card, which is where it was reported.
                    // Everything in this row is as wide as it needs to be, and this is what takes
                    // the rest.
                    Spacer(minLength: 8)

                    if let action {
                        Link(destination: action.url) {
                            Text(action.title).activityAction()
                        }
                        .fixedSize()
                    }
                }
            }
        }
        // **The card claims the width, and nothing else does it for it.** An activity's content is
        // laid out at its own ideal size and centred, so without this the whole card sat in the
        // middle of the Lock Screen with the name and the timer bunched together: a `Spacer` only
        // takes the room it is *offered*, and a view that does not ask for the width is not offered
        // any. Both cards this replaced carried the same frame, and it was dropped in the rewrite.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// A session's state, as the colour of the dot on its tile.
///
/// Three states rather than one per activity phase, because the two activities have four phases
/// and two between them: "waiting", "reconnecting" and "connecting" all mean the same thing to a
/// reader glancing at a Lock Screen, which is that nothing is flowing yet and nothing is broken.
///
/// The colours are copies of `ColorPalette`'s (`MacCast/Theme.swift`), which this target cannot
/// link: the widget extension builds against SwiftUI and WidgetKit alone. The host's palette is a
/// copy of the same values for the same reason, and this is the second one.
enum ActivityTone {
    case live
    case pending
    case lost

    var tint: Color {
        switch self {
        case .live: return .green
        case .pending: return Color(red: 0.97, green: 0.75, blue: 0.35)
        case .lost: return Color(red: 0.98, green: 0.45, blue: 0.40)
        }
    }
}

/// One thing a card can do, which is always a link: a widget cannot run the app's code, so every
/// control on one of these is a URL the app answers.
struct ActivityCardAction {
    let title: String
    let url: URL
}

/// The subject of the card: one glyph in a rounded tile, with the session's state in a dot on its
/// corner. The dot is the app's own mark, drawn the way the app's rows draw it: in the corner and
/// ringed, so a green dot on a green-ish wallpaper still reads as a dot.
private struct ActivityTile: View {
    let symbol: String
    let tone: ActivityTone

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: symbol)
                .font(.system(size: ActivityCard.tileGlyph, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: ActivityCard.tile, height: ActivityCard.tile)
                .background(
                    .white.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: ActivityCard.tileCorner, style: .continuous)
                )

            Circle()
                .fill(tone.tint)
                .frame(width: 9, height: 9)
                // The ring is the card's own fill, so it reads as the tile showing through rather
                // than as a colour of its own.
                .overlay(Circle().strokeBorder(ActivityCard.backgroundTint, lineWidth: 1.5))
                .offset(x: 2, y: 2)
        }
        // The state is in the words beside it and the kind is in the glyph, which VoiceOver reads
        // as "macbook", a symbol name rather than a sentence.
        .accessibilityHidden(true)
    }
}

private extension View {
    /// The way out, or the way back in.
    func activityAction() -> some View {
        font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(.white.opacity(0.16), in: Capsule())
    }
}
