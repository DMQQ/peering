import Foundation

/// What a ``MessageKind/stream`` frame carries.
public struct StreamFrame: Equatable, Sendable {
    public let stream: StreamID
    public let pipe: ControlPipeFrame

    public init(stream: StreamID, pipe: ControlPipeFrame) {
        self.stream = stream
        self.pipe = pipe
    }

    public func encoded() -> Data {
        var out = Data([stream.rawValue])
        out.append(pipe.encoded())
        return out
    }

    public static func decode(_ bytes: Data) -> StreamFrame? {
        let bytes = Data(bytes)
        guard let first = bytes.first, let stream = StreamID(rawValue: first),
              let pipe = ControlPipeFrame.decode(bytes.dropFirst())
        else { return nil }
        return StreamFrame(stream: stream, pipe: pipe)
    }
}
