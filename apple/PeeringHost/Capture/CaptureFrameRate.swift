import Foundation

/// Set on the stream as a minimum interval and on the encoder as its timeline; an enum keeps them the same number. `oneTwenty` only yields frames from a display faster than 60 Hz.
enum CaptureFrameRate: Int, CaseIterable, Sendable {
    case thirty = 30
    case sixty = 60
    case oneTwenty = 120
}
