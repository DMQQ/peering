import PeeringKit
import RemoteCore
import SwiftUI

extension SessionSurface {
    static let pointerPadHeight: CGFloat = 200

    var pointerPad: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return ZStack {
            RemoteDockDotField(touch: pointerPadTouch, ripple: pointerPadRipple)
            RemoteDockPad(actions: pointerPadActions)
        }
        .clipShape(shape)
        .frame(height: Self.pointerPadHeight)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { pointerPadSize = $0 }
        // Outlined, not glass: it sits inside the panel's own glass, and glass on glass reads as one muddy surface.
        .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .contentShape(shape)
        .accessibilityElement()
        .accessibilityLabel(String(localized: "Trackpad"))
    }

    private var pointerPadActions: RemoteDockPadActions {
        RemoteDockPadActions(
            onMove: movePointer(byPadFraction:),
            onTap: sendJoystickClick,
            onTwoFingerTap: sendJoystickRightClick,
            onScroll: { model.send(.scroll(dx: $0.width * ScrollNotch.pixelsPerPoint, dy: $0.height * ScrollNotch.pixelsPerPoint)) },
            onDragBegin: {
                isPointerPadDragging = true
                model.send(.mouseMove(to: remoteCursor))
                model.send(.mouseDown(button: .left))
            },
            onDragEnd: {
                guard isPointerPadDragging else { return }
                isPointerPadDragging = false
                model.send(.mouseUp(button: .left))
            },
            onTouch: { pointerPadTouch = $0 },
            onPress: { pointerPadRipple = RemoteDockRipple(point: $0, start: .now) },
            onSwipe: { swipe in
                for command in swipe.commands(spaces: model.catalog?.spaceInfo) { model.send(command) }
            }
        )
    }

    /// One scale for both axes, taken from the pad's width: a pad is wider than it is tall, so scaling each axis by its own length made a point of upward travel worth three of sideways.
    private func movePointer(byPadFraction fraction: CGSize) {
        let points = model.capturePointSize
        guard pointerPadSize.width > 0, points.width > 0 else { return }
        let scale = points.width * TrackpadEngine.defaultSensitivity
        let travel = CGSize(
            width: fraction.width * scale,
            height: fraction.height * pointerPadSize.height / pointerPadSize.width * scale
        )
        if isPointerPadDragging {
            // The host posts a joystick move as a plain mouse move, which would not drag what is held; an absolute position with the button down does.
            let speed = CGFloat(model.pointerSpeed)
            advanceClientCursor(by: CGSize(width: travel.width * speed, height: travel.height * speed))
            model.send(.mouseMove(to: remoteCursor))
        } else {
            sendJoystick(travel)
        }
    }
}
