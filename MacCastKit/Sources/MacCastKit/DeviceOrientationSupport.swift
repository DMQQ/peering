import Foundation

/// Telling a Mac which way the phone is held, and the one question that has to be answered first.
public enum DeviceOrientationSupport {
    public static func maySend(hostDeclared declared: Bool?) -> Bool {
        declared == true
    }
}
