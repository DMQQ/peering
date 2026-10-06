import Foundation

/// The request is a command an older host cannot decode, so sending it to a Mac that has not said it understands ends the session.
public enum SourceThumbnailSupport {
    /// Only an explicit `true`: ``ServerHello/supportsSourceThumbnails`` is `nil` for a Mac built before the field existed, and an unknown command is a decode failure, so treating `nil` as fine costs the session.
    public static func maySend(hostDeclared declared: Bool?) -> Bool {
        declared == true
    }
}
