import Foundation

extension SessionModel {
    func memoryWarningReceived() {
        for session in sessions where session.isLive { session.logEvent("Memory warning, trimming buffers") }
        for session in sessions { session.trimMemory() }
    }

    func powerStateChanged() {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard lowPower != isLowPowerMode else { return }
        isLowPowerMode = lowPower
        for session in sessions where session.isLive { session.logEvent(lowPower ? "Low Power Mode on, limiting quality" : "Low Power Mode off") }
        for session in sessions where session.isLive { session.refreshQualityCeiling() }
    }
}
