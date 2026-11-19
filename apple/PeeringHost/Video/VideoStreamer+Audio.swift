import Foundation
import PeeringKit
import RemoteCore
import os

extension VideoStreamer {
    func sendAudioConfig(_ config: AudioStreamConfig) {
        let shouldPump = lock.withLock { () -> Bool in
            audioConfig = config
            audioConfigOwed = peer != nil
            pendingAudio.removeAll()
            return peer != nil && !sending
        }
        if shouldPump { pump() }
    }

    var isAudioEnabled: Bool { lock.withLock { audioEnabled } }

    func setAudioEnabled(_ enabled: Bool) {
        lock.withLock {
            audioEnabled = enabled
            if !enabled { pendingAudio.removeAll() }
        }
    }

    func routeAudio(of video: PeerConnection, through control: PeerConnection) {
        lock.withLock {
            audioRouteVideo = video
            audioRouteControl = control
        }
    }

    private enum AudioPath {
        case datagrams(VideoDatagramLane, [Data])
        case control(PeerConnection, Data)
    }

    func sendAudioFrame(_ frame: EncodedAudioFrame) {
        let own = lock.withLock { () -> AudioPath? in
            guard audioEnabled, audioConfig != nil, !audioConfigOwed, transport != .control else { return nil }
            let path: AudioPath
            if let datagrams {
                path = .datagrams(datagrams, datagrams.seal(kind: .audioFrame, payload: frame.encoded()))
            } else if let control = audioRouteControl, let peer, audioRouteVideo === peer {
                path = .control(control, FrameEncoder.encode(Frame(kind: .audioFrame, payload: frame.encoded())))
            } else {
                return nil
            }
            _stats.audioFramesSent += 1
            _stats.audioBytesSent += frame.samples.count + EncodedAudioFrame.headerSize
            return path
        }
        // Its own path: a sound is a few hundred bytes and goes the moment it exists, so a picture still being sent never holds it. On the LAN that is the control connection, since on the video connection it would queue behind the picture's bytes.
        switch own {
        case .datagrams(let lane, let payloads):
            lane.sendUrgent(payloads)
            return
        case .control(let control, let bytes):
            control.send(bytes)
            return
        case nil:
            break
        }

        let shouldPump = lock.withLock { () -> Bool in
            guard audioEnabled else { return false }
            guard peer != nil, audioConfig != nil else {
                if !loggedAudioWithoutPeer {
                    loggedAudioWithoutPeer = true
                    streamerLog.notice("sound from the Mac: audio is being captured but no video connection is attached to send it on")
                }
                return false
            }
            if pendingAudio.push(frame) { _stats.audioFramesDropped += 1 }
            return !sending
        }
        if shouldPump { pump() }
    }
}
