import Foundation

/// What the composer turns a draft and its attached files into.
public enum AgentDraft {
    /// The files go first as `@path`, the CLIs' own way to read one; the transcript turns them back into chips.
    public static func prompt(draft: String, attachedPaths: [String]) -> String {
        (attachedPaths.map { "@" + $0 } + [draft]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Nothing to send while a file is still uploading, and an empty draft needs at least one file that arrived.
    public static func canSend(draft: String, attachedCount: Int, isUploading: Bool) -> Bool {
        guard !isUploading else { return false }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachedCount > 0
    }

    /// Where an uploaded file lands on the Mac: in the chat's own folder.
    public static func attachmentPath(folder: String, name: String) -> String {
        folder.hasSuffix("/") ? folder + name : folder + "/" + name
    }
}
