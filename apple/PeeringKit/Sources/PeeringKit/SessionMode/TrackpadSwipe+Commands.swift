import RemoteCore

extension TrackpadSwipe {
    /// As on a Mac trackpad: left or right moves a desktop (the content follows the fingers), up opens
    /// Mission Control, down shows the app's windows.
    ///
    /// Left and right jump to the desktop beside the one the Mac reports as current. The relative chord
    /// only stands in when the Mac sent no desktop list, since it moves from wherever the system thinks
    /// it is rather than from the desktop being shown.
    public func commands(spaces: SpaceInfo?) -> [RemoteCommand] {
        switch self {
        case .left: Self.stepSpace(1, spaces: spaces)
        case .right: Self.stepSpace(-1, spaces: spaces)
        case .up: Self.controlChord(126)
        case .down: Self.controlChord(125)
        }
    }

    private static func stepSpace(_ step: Int, spaces: SpaceInfo?) -> [RemoteCommand] {
        guard let display = spaces?.displays.first, let current = display.current, display.count > 0 else {
            return [.switchSpace(direction: step < 0 ? .left : .right)]
        }
        let target = min(max(current + step, 1), display.count)
        guard target != current else { return [] }
        return [.switchToSpace(display: display.displayID, index: target)]
    }

    private static func controlChord(_ keyCode: UInt16) -> [RemoteCommand] {
        [.keyDown(keyCode: keyCode, modifiers: .control), .keyUp(keyCode: keyCode, modifiers: .control)]
    }
}
