import Foundation

public enum PicturePause {
    /// Whether a client may ask this Mac to pause.
    public static func mayAsk(hostDeclared declared: Bool?) -> Bool {
        declared == true
    }
}
