import CoreGraphics
import Foundation

/// Keeps the screen changing, so the capture pipeline has something to encode.
///
/// **Why this exists as a tool rather than as a flag on the probe.** Every check that touches
/// capture has a quiet-screen failure mode and an active-screen one, and they are not the
/// same test. On a still screen ScreenCaptureKit reports `.idle`, the encoder produces almost
/// nothing, and any assertion about frames per second, about the queue depth, or about which
/// frame happens to be first after a client attaches is measuring an idle machine. The
/// frame-ordering bug this was written to investigate only appears when the encoder is
/// mid-stream at the moment a client connects: a frame it had already encoded is delivered
/// after the attach, and it is a delta.
///
/// The cursor is used as the source of motion because it needs no window, no focus, and no
/// cooperation — and because display capture includes it, so moving it genuinely changes the
/// captured pixels. It is put back where it started, so a run leaves no trace on screen.
///
/// usage: maccast-activity [seconds] [--hz N] [--quiet]

private func argument(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}

let arguments = Array(CommandLine.arguments.dropFirst())
let seconds = arguments.first.flatMap { $0.hasPrefix("--") ? nil : Double($0) } ?? 10
let rate = argument("--hz", in: arguments).flatMap(Double.init) ?? 60
let quiet = arguments.contains("--quiet")

guard seconds > 0, rate > 0 else {
    FileHandle.standardError.write(Data("activity: seconds and --hz must be positive\n".utf8))
    exit(2)
}

let bounds = CGDisplayBounds(CGMainDisplayID())
guard bounds.width > 0, bounds.height > 0 else {
    FileHandle.standardError.write(Data("activity: no main display\n".utf8))
    exit(1)
}

// Restored on every exit path, including the ones that do not reach the end of the loop.
let origin = CGEvent(source: nil)?.location ?? CGPoint(x: bounds.midX, y: bounds.midY)
func restore() {
    CGWarpMouseCursorPosition(origin)
    // Warping disassociates the cursor from the mouse so that the physical device does not
    // fight the synthetic position; without this the user's next real movement would jump.
    CGAssociateMouseAndMouseCursorPosition(1)
}
atexit(restore)

if !quiet {
    print("activity: moving the cursor for \(seconds)s at \(Int(rate)) Hz on a "
        + "\(Int(bounds.width))×\(Int(bounds.height))pt display")
}

// A Lissajous figure rather than a circle or a line: the two axes are incommensurate, so the
// path does not retrace itself and the picture keeps changing instead of settling into a
// loop the encoder could predict and compress away to almost nothing.
let deadline = Date().addingTimeInterval(seconds)
let interval = useconds_t(1_000_000 / rate)
var t = 0.0
var moves = 0

while Date() < deadline {
    t += 0.02
    let x = bounds.midX + cos(t) * bounds.width * 0.35
    let y = bounds.midY + sin(t * 0.61) * bounds.height * 0.35
    CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
    CGAssociateMouseAndMouseCursorPosition(1)
    moves += 1
    usleep(interval)
}

if !quiet {
    print("activity: \(moves) move(s), cursor restored")
}
