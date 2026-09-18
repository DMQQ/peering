import RemoteCore
import SwiftUI

/// What a shell's colour numbers mean on screen.
///
/// The xterm defaults rather than the app's palette, and that is a deliberate departure from how
/// everything else here is coloured. ``ColorPalette`` exists so that this app looks like one
/// product; a shell's output is not this app's to restyle. `LS_COLORS`, `git`'s diff colours and
/// every `--color=auto` a server is configured with are written against *these* sixteen values,
/// and a `git status` repainted in the app's blue would be output that looks different here than
/// in any other terminal the user has ever opened — which reads as the app being wrong, not as
/// the app having taste.
enum TerminalPalette {
    /// The first sixteen, which are the ones anything ever names.
    ///
    /// Not pure primaries except where xterm is not either: these are the values xterm has used
    /// for decades, and matching them matters more than being tasteful. A pure `#0000ff` blue is
    /// hard to read on a black background, which is exactly why the real one is darker.
    private static let ansi: [Color] = [
        rgb(0x00, 0x00, 0x00),  // 0  black
        rgb(0xcd, 0x00, 0x00),  // 1  red
        rgb(0x00, 0xcd, 0x00),  // 2  green
        rgb(0xcd, 0xcd, 0x00),  // 3  yellow
        rgb(0x00, 0x00, 0xee),  // 4  blue
        rgb(0xcd, 0x00, 0xcd),  // 5  magenta
        rgb(0x00, 0xcd, 0xcd),  // 6  cyan
        rgb(0xe5, 0xe5, 0xe5),  // 7  white
        rgb(0x7f, 0x7f, 0x7f),  // 8  bright black
        rgb(0xff, 0x00, 0x00),  // 9  bright red
        rgb(0x00, 0xff, 0x00),  // 10 bright green
        rgb(0xff, 0xff, 0x00),  // 11 bright yellow
        rgb(0x5c, 0x5c, 0xff),  // 12 bright blue
        rgb(0xff, 0x00, 0xff),  // 13 bright magenta
        rgb(0x00, 0xff, 0xff),  // 14 bright cyan
        rgb(0xff, 0xff, 0xff),  // 15 bright white
    ]

    /// The six levels the colour cube steps through. Zero, then the 95/135/175/215/255 scale —
    /// not evenly spaced, because it was chosen for the hardware it had to look right on.
    private static let cubeLevels: [UInt8] = [0, 95, 135, 175, 215, 255]

    /// A colour for a shell's value, or `nil` for "whatever the terminal's default is".
    ///
    /// Nil rather than a chosen default, because the default is not a colour this file gets to
    /// pick: it is what the surrounding text is already drawn in, and returning a specific black
    /// here would be unreadable the first time the terminal is not.
    static func color(for style: TerminalStyle) -> Color? {
        switch style {
        case .default:
            return nil
        case .rgb(let red, let green, let blue):
            return rgb(red, green, blue)
        case .indexed(let index):
            return color(forIndex: index)
        }
    }

    private static func color(forIndex index: UInt8) -> Color {
        let value = Int(index)
        if value < ansi.count {
            return ansi[value]
        }
        // 16–231 are a 6×6×6 cube: red major, then green, then blue.
        if value < 232 {
            let n = value - 16
            return rgb(
                cubeLevels[n / 36],
                cubeLevels[(n / 6) % 6],
                cubeLevels[n % 6]
            )
        }
        // 232–255 are a greyscale ramp from 8 to 238 in steps of 10 — the one part of the
        // 256-colour space that is evenly spaced, and the part a `git diff` uses for context.
        let level = UInt8(8 + (value - 232) * 10)
        return rgb(level, level, level)
    }

    private static func rgb(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> Color {
        Color(
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255
        )
    }

    /// A shell's styled lines, as one string to draw.
    ///
    /// Here rather than written out in each panel, and that is the whole reason it is a function:
    /// the Mac's terminal and an SSH one show the same kind of thing, and two copies of these
    /// rules are two places for them to drift — which is exactly what had happened, with one
    /// terminal coloured by ANSI and the other not coloured at all.
    static func attributed(_ lines: [TerminalStyledLine], fontSize: CGFloat) -> AttributedString {
        var rendered = AttributedString()

        for line in lines {
            // A line the shell coloured itself is left exactly as it asked for. Only a line with
            // no colour of its own falls back to the word-matching guess — which predates any of
            // this, and is still the only thing that marks a failure in the plain output of a
            // command that never learned to colour.
            let isColoured = line.runs.contains {
                $0.foreground != .default || $0.background != .default
            }

            for run in line.runs {
                var piece = AttributedString(run.text)

                if let colour = color(for: run.foreground) {
                    // Dim is a shell asking for *less* of a colour — `ls` marks the things you are
                    // least likely to want with it — and there is no dimmer weight of a colour, so
                    // it is faded rather than darkened.
                    piece.foregroundColor = run.dim ? colour.opacity(0.6) : colour
                } else if !isColoured {
                    switch line.kind {
                    case .error: piece.foregroundColor = ColorPalette.danger
                    case .warning: piece.foregroundColor = ColorPalette.caution
                    case .plain: break
                    }
                }

                // Backgrounds are not decoration: `htop`'s header and its meter bars are drawn
                // entirely out of them, and a terminal that shows the foreground and drops the
                // background turns a full-screen program into text with gaps in it.
                if let background = color(for: run.background) {
                    piece.backgroundColor = background
                }

                if run.bold {
                    piece.font = .system(size: fontSize, weight: .bold, design: .monospaced)
                }

                rendered.append(piece)
            }

            rendered.append(AttributedString("\n"))
        }

        return rendered
    }
}
