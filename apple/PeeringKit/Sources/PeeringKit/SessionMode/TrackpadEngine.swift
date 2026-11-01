import Foundation

/// Finger motion on the remote dock's pad, turned into the Mac pointer's absolute position and button events. The view recognises taps and drags; this keeps the cursor, the sensitivity and a button that must never be left down.
public struct TrackpadEngine: Sendable {
    public enum Event: Equatable, Sendable {
        case move(x: Double, y: Double)
        case press(right: Bool)
        case release(right: Bool)
        case scroll(dx: Double, dy: Double)
    }

    /// A pad width of finger travel moves the pointer this many screen widths.
    public static let defaultSensitivity = 1.4
    public static let tapMaxMovement = 10.0
    public static let tapMaxSeconds = 0.25
    public static let dragHoldSeconds = 0.3

    public private(set) var x = 0.5
    public private(set) var y = 0.5
    public private(set) var isDragging = false
    public var sensitivity: Double

    public init(sensitivity: Double = TrackpadEngine.defaultSensitivity) {
        self.sensitivity = sensitivity
    }

    /// The Mac's own report of where the pointer is, so the first move starts from the truth.
    public mutating func adopt(x: Double, y: Double) {
        self.x = Self.clamp(x)
        self.y = Self.clamp(y)
    }

    public mutating func move(dx: Double, dy: Double, padWidth: Double, padHeight: Double) -> [Event] {
        guard padWidth > 0, padHeight > 0 else { return [] }
        x = Self.clamp(x + dx / padWidth * sensitivity)
        y = Self.clamp(y + dy / padHeight * sensitivity)
        return [.move(x: x, y: y)]
    }

    public func tap() -> [Event] {
        [.move(x: x, y: y), .press(right: false), .release(right: false)]
    }

    public func twoFingerTap() -> [Event] {
        [.move(x: x, y: y), .press(right: true), .release(right: true)]
    }

    public mutating func beginDrag() -> [Event] {
        guard !isDragging else { return [] }
        isDragging = true
        return [.move(x: x, y: y), .press(right: false)]
    }

    /// Also what a cancelled touch calls: a button left down on the Mac would turn every later move into a drag.
    public mutating func endDrag() -> [Event] {
        guard isDragging else { return [] }
        isDragging = false
        return [.release(right: false)]
    }

    public func scroll(dx: Double, dy: Double) -> [Event] {
        [.scroll(dx: dx * ScrollNotch.pixelsPerPoint, dy: dy * ScrollNotch.pixelsPerPoint)]
    }

    private static func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
}
