import Foundation

/// Audio frames waiting to leave the Mac, sharing one send slot with the picture.
///
/// A single "newest wins" slot threw away every frame that arrived while a picture was being sent, which on a slow path is most of them and sounds like half the audio missing. Frames queue instead, up to a bound, and audio goes ahead of the picture a few frames at a time so a large picture cannot hold it back.
public struct AudioSendQueue<Element> {
    /// About a third of a second of sound: past that the audio is too late to be worth playing, and the oldest goes.
    public let capacity: Int
    /// Audio frames sent in a row before the picture gets a turn.
    public let burst: Int

    private var elements: [Element] = []
    private var sentSincePicture: Int

    public init(capacity: Int = 16, burst: Int = 4) {
        self.capacity = capacity
        self.burst = burst
        self.sentSincePicture = burst
    }

    public var isEmpty: Bool { elements.isEmpty }

    /// Returns whether the oldest frame was dropped to make room.
    @discardableResult
    public mutating func push(_ element: Element) -> Bool {
        elements.append(element)
        guard elements.count > capacity else { return false }
        elements.removeFirst()
        return true
    }

    /// The next frame if it is audio's turn, otherwise nil: either nothing is queued, or a picture is waiting and has been passed over `burst` times.
    public mutating func popForTurn(pictureWaiting: Bool) -> Element? {
        guard !elements.isEmpty else { return nil }
        if pictureWaiting, sentSincePicture >= burst {
            sentSincePicture = 0
            return nil
        }
        sentSincePicture += 1
        return elements.removeFirst()
    }

    /// A new client starts with the picture, which carries the keyframe it cannot start without.
    public mutating func reset() {
        elements.removeAll()
        sentSincePicture = burst
    }

    public mutating func removeAll() {
        elements.removeAll()
    }
}
