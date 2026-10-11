import Foundation

extension MacSession {
    /// The Mac's name as the user chose to see it, falling back to the name the Mac gave itself.
    var shownName: String? {
        hostName.map { model.shownName(hostID: hostID, fallback: $0) }
    }
}
