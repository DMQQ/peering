import Foundation
import RemoteCore

/// What the host model hands the server to call back into. Set from the main actor, read from the server's queue, so each is behind one lock.
final class HostServerCallbacks: @unchecked Sendable {
    private let lock = NSLock()
    private var pushNeeded: (@Sendable (String, String, String) -> Void)?
    private var agentPushNeeded: (@Sendable (String, String, String, RelayPushAction?) -> Void)?
    private var activityPush: (@Sendable (RelayActivityPush, @escaping @Sendable () -> Void) -> Void)?
    private var agentActivity: (@Sendable (Bool) -> Void)?
    private var event: (@Sendable (HostEvent) -> Void)?
    private var command: (@Sendable (RemoteCommand) -> Void)?
    private var videoConnection: (@Sendable (PeerConnection) -> Void)?
    private var videoTransport: (@Sendable (Data?, VideoTransportRequest, PeerConnection) -> Void)?
    private var videoKeyRequest: (@Sendable (Data?, RelaySession) -> Data?)?
    private var videoEnabled: (@Sendable (Data?, Bool) -> Void)?
    private var clientVideoCodecs: (@Sendable (Data?, [String]?) -> Void)?
    private var requestClipboard: (@Sendable (@escaping @Sendable (ClipboardPayload?) -> Void) -> Void)?
    private var receiveClipboard: (@Sendable (ClipboardPayload, @escaping @Sendable () -> Void) -> Void)?

    /// Called when a terminal needs attention, or has finished a command worth mentioning.
    var onPushNeeded: (@Sendable (String, String, String) -> Void)? {
        get { lock.withLock { pushNeeded } }
        set { lock.withLock { pushNeeded = newValue } }
    }

    /// Called when an agent chat needs the person while the phone may be suspended; the action, when present, lets the notification answer.
    var onAgentPushNeeded: (@Sendable (String, String, String, RelayPushAction?) -> Void)? {
        get { lock.withLock { agentPushNeeded } }
        set { lock.withLock { agentPushNeeded = newValue } }
    }

    /// Called with a Live Activity update to hand the relay, and a completion to run once it has been sent.
    var onActivityPush: (@Sendable (RelayActivityPush, @escaping @Sendable () -> Void) -> Void)? {
        get { lock.withLock { activityPush } }
        set { lock.withLock { activityPush = newValue } }
    }

    /// Called when the set of chats that are doing something becomes empty, or stops being empty.
    var onAgentActivity: (@Sendable (Bool) -> Void)? {
        get { lock.withLock { agentActivity } }
        set { lock.withLock { agentActivity = newValue } }
    }

    var onEvent: (@Sendable (HostEvent) -> Void)? {
        get { lock.withLock { event } }
        set { lock.withLock { event = newValue } }
    }

    var onCommand: (@Sendable (RemoteCommand) -> Void)? {
        get { lock.withLock { command } }
        set { lock.withLock { command = newValue } }
    }

    var onVideoConnection: (@Sendable (PeerConnection) -> Void)? {
        get { lock.withLock { videoConnection } }
        set { lock.withLock { videoConnection = newValue } }
    }

    /// Called when a client asks for video to move between transports, with the key that
    /// identifies it and the control connection the request arrived on.
    var onVideoTransport: (@Sendable (Data?, VideoTransportRequest, PeerConnection) -> Void)? {
        get { lock.withLock { videoTransport } }
        set { lock.withLock { videoTransport = newValue } }
    }

    /// Called when a relayed client asks for the secret that seals video datagrams, with the
    /// key that identifies it and the allocation the session came from.
    var onVideoKeyRequest: (@Sendable (Data?, RelaySession) -> Data?)? {
        get { lock.withLock { videoKeyRequest } }
        set { lock.withLock { videoKeyRequest = newValue } }
    }

    /// Called when a client asks for the picture to be turned on or off, with the key that
    /// identifies it.
    var onVideoEnabled: (@Sendable (Data?, Bool) -> Void)? {
        get { lock.withLock { videoEnabled } }
        set { lock.withLock { videoEnabled = newValue } }
    }

    /// Called with the key that identifies a client and the codecs it decodes, and with nil once its last session ends.
    var onClientVideoCodecs: (@Sendable (Data?, [String]?) -> Void)? {
        get { lock.withLock { clientVideoCodecs } }
        set { lock.withLock { clientVideoCodecs = newValue } }
    }

    var onRequestClipboard: (@Sendable (@escaping @Sendable (ClipboardPayload?) -> Void) -> Void)? {
        get { lock.withLock { requestClipboard } }
        set { lock.withLock { requestClipboard = newValue } }
    }

    var onReceiveClipboard: (@Sendable (ClipboardPayload, @escaping @Sendable () -> Void) -> Void)? {
        get { lock.withLock { receiveClipboard } }
        set { lock.withLock { receiveClipboard = newValue } }
    }
}
