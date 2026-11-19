import Dispatch
import Foundation

/// Writes packets at the times quiche asks for, in order, so a large picture is spread over the round trip instead of arriving at the Wi-Fi as one burst. Confined to the queue it is given.
final class QuicPacer {
    private let queue: DispatchQueue
    private let write: (QuicConnection.Packet) -> Void
    private var waiting: [(packet: QuicConnection.Packet, due: DispatchTime)] = []
    private var scheduled = false
    /// Packets due within this are written at once: waking a timer for less costs more than it saves.
    private static let slack: Duration = .microseconds(500)

    init(queue: DispatchQueue, write: @escaping (QuicConnection.Packet) -> Void) {
        self.queue = queue
        self.write = write
    }

    func submit(_ packets: [QuicConnection.Packet]) {
        let now = DispatchTime.now()
        for packet in packets {
            let (seconds, attoseconds) = packet.delay.components
            let nanoseconds = UInt64(max(0, seconds)) * 1_000_000_000 + UInt64(max(0, attoseconds) / 1_000_000_000)
            waiting.append((packet, DispatchTime(uptimeNanoseconds: now.uptimeNanoseconds + nanoseconds)))
        }
        drain()
    }

    func reset() {
        waiting = []
    }

    private func drain() {
        let horizon = DispatchTime.now().uptimeNanoseconds + UInt64(Self.slack.components.attoseconds / 1_000_000_000)
        // Strictly in order: a later packet is never written before an earlier one that is still waiting.
        while let first = waiting.first, first.due.uptimeNanoseconds <= horizon {
            waiting.removeFirst()
            write(first.packet)
        }
        guard let next = waiting.first, !scheduled else { return }
        scheduled = true
        queue.asyncAfter(deadline: next.due) { [weak self] in
            guard let self else { return }
            scheduled = false
            drain()
        }
    }
}
