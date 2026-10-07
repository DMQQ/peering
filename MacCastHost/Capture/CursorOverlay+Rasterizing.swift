import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import RemoteCore
import os

extension CursorOverlay {
    /// Once only: the cause is a property of the stream or pixel format, so it holds for every frame, and a missing pointer looks like one never asked for. Not called for the pointer being elsewhere.
    func report(_ reason: String) {
        let isFirst = lock.withLock { () -> Bool in
            guard !reportedRefusal else { return false }
            reportedRefusal = true
            return true
        }
        guard isFirst else { return }
        overlayLog.notice("no pointer drawn into a frame: \(reason, privacy: .public)")
    }

    /// A scanline fill: the work is in the outline, not its area.
    func rasterize(
        _ pass: Pass,
        tip: CGPoint,
        scale: CGFloat,
        plane: UnsafeMutablePointer<UInt8>,
        stride: Int,
        width: Int,
        height: Int
    ) {
        // One crossing per edge is the worst case, which keeps the fixed array honest.
        guard pass.range.count <= intersections.count else { return }

        let last = pass.range.upperBound - 1
        guard last > pass.range.lowerBound else { return }

        var minX = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude

        var index = pass.range.lowerBound
        while index < last {
            let a = vertices[index]
            let b = vertices[index + 1]
            let ax = tip.x + a.x * scale
            let bx = tip.x + b.x * scale
            let ay = tip.y + a.y * scale
            let by = tip.y + b.y * scale

            minX = min(minX, min(ax, bx))
            maxX = max(maxX, max(ax, bx))
            minY = min(minY, min(ay, by))
            maxY = max(maxY, max(ay, by))

            index += 1
        }

        let firstRow = max(0, Int(minY.rounded(.down)))
        let lastRow = min(height - 1, Int(maxY.rounded(.up)))
        guard firstRow <= lastRow, maxX >= 0, minX <= CGFloat(width - 1) else { return }

        for row in firstRow...lastRow {
            let sample = CGFloat(row) + 0.5
            var crossings = 0

            var index = pass.range.lowerBound
            while index < last {
                let ay = tip.y + vertices[index].y * scale
                let by = tip.y + vertices[index + 1].y * scale

                // Half-open in y, so a row through a vertex is counted by one of the two edges meeting there, not both.
                if (ay <= sample) != (by <= sample) {
                    let ax = tip.x + vertices[index].x * scale
                    let bx = tip.x + vertices[index + 1].x * scale
                    let t = (sample - ay) / (by - ay)
                    intersections[crossings] = ax + t * (bx - ax)
                    crossings += 1
                }

                index += 1
            }

            guard crossings >= 2 else { continue }

            // By hand: at most seven, and a sort called eight times a frame must not allocate.
            for i in 1..<crossings {
                let value = intersections[i]
                var j = i
                while j > 0, intersections[j - 1] > value {
                    intersections[j] = intersections[j - 1]
                    j -= 1
                }
                intersections[j] = value
            }

            let line = plane + row * stride
            var pair = 0
            while pair + 1 < crossings {
                let from = max(0, Int((intersections[pair] - 0.5).rounded(.up)))
                let to = min(width - 1, Int((intersections[pair + 1] - 0.5).rounded(.down)))
                if from <= to {
                    memset(line + from, Int32(pass.value), to - from + 1)
                }
                pair += 2
            }
        }
    }

    static func shape() -> (vertices: [CGPoint], passes: [Pass]) {
        var vertices: [CGPoint] = []
        var passes: [Pass] = []

        for index in outline.indices {
            let quad = stroke(from: outline[index], to: outline[(index + 1) % outline.count])
            guard let first = quad.first else { continue }
            let start = vertices.count
            vertices.append(contentsOf: quad)
            vertices.append(first)
            passes.append(Pass(range: start..<vertices.count, value: edge))
        }

        let start = vertices.count
        vertices.append(contentsOf: outline)
        vertices.append(outline[0])
        passes.append(Pass(range: start..<vertices.count, value: ink))

        return (vertices, passes)
    }

    private static func stroke(from a: CGPoint, to b: CGPoint) -> [CGPoint] {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return [] }

        let half = edgeWidth / 2
        let nx = -dy / length * half
        let ny = dx / length * half

        return [
            CGPoint(x: a.x + nx, y: a.y + ny),
            CGPoint(x: b.x + nx, y: b.y + ny),
            CGPoint(x: b.x - nx, y: b.y - ny),
            CGPoint(x: a.x - nx, y: a.y - ny),
        ]
    }
}
