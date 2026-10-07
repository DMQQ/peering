import CryptoKit
import Crypto
import Foundation
import Network
import Security
import os

extension ClientSession {
    /// Arms the next attempt at the video socket, if one is left. The guard refuses an ended or connecting session, a relayed one, and a client that asked for no picture.
    func scheduleVideoReconnect(generation: UInt64) {
        lock.lock()
        // `video == nil` is in here because a socket replaced between the close and this call has nothing to dial for, and a rung spent on it is lost to the next real failure.
        guard videoReconnectTask == nil, video == nil, state == .ready, wantsPicture,
              !usesRelayedSingleStream
        else {
            lock.unlock()
            return
        }
        guard let delay = videoReconnectLadder.next() else {
            lock.unlock()
            // A session left up without its picture sat on "Stream paused" for good after a network
            // switch. Failing it hands the Mac to the session ladder, which redials on the new path.
            clientSessionLog.error("the video channel did not come back; failing the session")
            fail("The video channel did not come back.", reason: .videoLost)
            return
        }
        let task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            // The generation is re-read here and not merely at the arm above, because this is the
            // wait that can outlive what it was armed for. Whether the client still wants a picture
            // is deliberately *not* re-read: `openVideoIfNeeded` refuses to open one either way.
            let stillOurs = self.lock.withLock { () -> Bool in
                self.videoReconnectTask = nil
                return self.state == .ready && self.connectGeneration == generation
            }
            guard stillOurs else { return }
            self.openVideoIfNeeded()
        }
        // Assigned while the lock is still held: the task above may begin running the moment it is
        // created, and its first act under the lock is to clear this slot. Assigned outside it,
        // the body could clear a slot that had just been filled.
        videoReconnectTask = task
        lock.unlock()
    }

    /// Opens the relay's video datagram lane and asks the Mac for the key. The bind goes first: the relay forwards nothing to an address it has not been told about, and it learns it from a datagram of this end's token alone.
    func startVideoDatagrams() {
        lock.lock()
        guard wantsVideoDatagrams, videoDatagrams == nil, let relay = relaySession else {
            lock.unlock()
            return
        }
        let generation = connectGeneration
        lock.unlock()
        // Built outside the lock: its init resolves the relay's name with a blocking getaddrinfo,
        // which on a slow LTE resolver held the main thread past the launch watchdog.
        let socket: VideoDatagramSocket
        do {
            socket = try VideoDatagramSocket(
                host: relay.videoHost,
                port: relay.videoPort,
                token: relay.videoToken,
                label: "pl.dmq.peering.client.video.datagrams"
            )
        } catch {
            // Not fatal: without this socket the picture stays on the control stream. The wish is dropped rather than retried, since the cause (a token or port off the wire contract) would repeat.
            lock.withLock { wantsVideoDatagrams = false }
            clientSessionLog.error("could not open the relay's video datagram socket: \(String(describing: error), privacy: .public)")
            emit(.note("Could not open the relay's video path; the picture will share the control channel."))
            return
        }
        lock.lock()
        guard wantsVideoDatagrams, videoDatagrams == nil, connectGeneration == generation else {
            lock.unlock()
            socket.cancel()
            return
        }
        videoDatagrams = socket
        datagramFailures = 0
        reportedDatagramFailure = false
        lock.unlock()

        socket.onDatagram = { [weak self] datagram, source in
            self?.handleDatagram(datagram, from: source)
        }
        socket.onFailure = { [weak self, weak socket] error in
            clientSessionLog.error("the video datagram socket failed: \(error.localizedDescription, privacy: .public)")
            guard let self, let socket else { return }
            self.videoDatagramSocketFailed(socket)
        }
        // The bind and the keepalive that repeats it. A NAT binding that expires is a session
        // that stops receiving video without anything on either end reporting a problem.
        socket.start()

        emit(.note("Remote session open; asking the Mac to send the picture directly."))
        connection()?.send(Frame(kind: .videoKeyRequest))
    }

    func videoDatagramSocketFailed(_ socket: VideoDatagramSocket) {
        let tasks = lock.withLock { () -> (Task<Void, Never>?, Task<Void, Never>?)? in
            guard videoDatagrams === socket else { return nil }
            videoDatagrams = nil
            wantsVideoDatagrams = false
            videoOpener = nil
            videoSealer = nil
            reportedPath = .relay
            let direct = directPathTask
            let ping = lanePingTask
            directPathTask = nil
            lanePingTask = nil
            return (direct, ping)
        }
        guard let tasks else { return }
        tasks.0?.cancel()
        tasks.1?.cancel()
        socket.cancel()
        emit(.note("The relay's video path stopped responding."))
    }

    /// The Mac's answer to ``MessageKind/videoKeyRequest``. Only accepted once the socket exists, since a key with nowhere to receive would look like a working lane.
    func handleVideoKey(_ frame: Frame) {
        guard let grant = try? MessageCodec.decode(VideoKeyGrant.self, from: frame.payload),
              grant.secret.count == VideoKeySchedule.secretSize
        else {
            clientSessionLog.error("the Mac sent a video key this build could not read")
            return
        }

        let opener = VideoKeySchedule(secret: grant.secret).opener(direction: .hostToClient)
        let accepted = lock.withLock { () -> Bool in
            guard videoDatagrams != nil else { return false }
            videoOpener = opener
            return true
        }
        guard accepted else { return }
        emit(.note("The Mac is sending video directly."))
        beginDirectPath(secret: grant.secret)
    }
}
