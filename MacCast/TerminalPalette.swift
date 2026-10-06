import RemoteCore
import SwiftUI

/// The xterm defaults, not the app's palette: `LS_COLORS` and `--color=auto` output is written against these sixteen values.
enum TerminalPalette {
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

    private static let cubeLevels: [UInt8] = [0, 95, 135, 175, 215, 255]

    /// Nil means the terminal's default, which is whatever the surrounding text is already drawn in.
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
        if value < 232 {
            let n = value - 16
            return rgb(
                cubeLevels[n / 36],
                cubeLevels[(n / 6) % 6],
                cubeLevels[n % 6]
            )
        }
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

    static func attributed(_ lines: [TerminalStyledLine], fontSize: CGFloat) -> AttributedString {
        var rendered = AttributedString()

        for line in lines {
            // A line the shell coloured itself is left as asked; only uncoloured lines get the word-matching failure guess.
            let isColoured = line.runs.contains {
                $0.foreground != .default || $0.background != .default
            }

            for run in line.runs {
                var piece = AttributedString(run.text)

                if let colour = color(for: run.foreground) {
                    // Dim has no dimmer colour weight, so it is faded rather than darkened.
                    piece.foregroundColor = run.dim ? colour.opacity(0.6) : colour
                } else if !isColoured {
                    switch line.kind {
                    case .error: piece.foregroundColor = ColorPalette.danger
                    case .warning: piece.foregroundColor = ColorPalette.caution
                    case .plain: break
                    }
                }

                // Backgrounds are not decoration: `htop`'s header and meters are drawn entirely from them.
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
