import Foundation
import RemoteCore
import os

extension VideoStreamer {
    func sendAudioConfig(_ config: AudioStreamConfig) {
        let shouldPump = lock.withLock { () -> Bool in
            audioConfig = config
            audioConfigOwed = peer != nil
            pendingAudio = nil
            return peer != nil && !sending
        }
        if shouldPump { pump() }
    }

    func sendAudioFrame(_ frame: EncodedAudioFrame) {
        let shouldPump = lock.withLock { () -> Bool in
            guard peer != nil, audioConfig != nil else { return false }
            if pendingAudio != nil { _stats.audioFramesDropped += 1 }
            pendingAudio = frame
            return !sending
        }
        if shouldPump { pump() }
    }
}
