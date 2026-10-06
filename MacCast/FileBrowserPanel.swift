import RemoteCore
import SwiftUI
import UniformTypeIdentifiers
import MacCastKit
import os

/// A folder on the Mac, as a list. Draws what it is given and asks for nothing: every tap is a callback, and ``TerminalScreen`` owns the session, path and cache, so one view serves both browsers. Drawn on the terminal's own black because it is what the terminal shows instead of its output.
struct FileBrowserPanel: View {
    let path: String?
    let directory: RemoteDirectory?
    let isLoading: Bool
    let failure: String?
    let showsHidden: Bool

    /// Supplied by whoever answers the callbacks: on the Mac a slow read is usually a permission prompt, on a server the network.
    /// `var` rather than `let` for the default: a `let` with an initial value is not part of the memberwise initialiser.
    var waitingHint: String? = nil

    /// For the folder upload, a run of hundreds of operations the user cannot see. A sentence rather than a bar: entries differ in size, so a count-filled bar would lie about how much is left.
    var progress: String? = nil

    var onOpen: (RemoteDirectoryEntry) -> Void
    var onNavigate: (String) -> Void
    /// Optional: the hub's browser has no shell to put a path into.
    var onRevealPath: ((String) -> Void)?
    var onReload: () -> Void

    /// Optional because the button is drawn from whether this is present; nil means a shell that has ended.
    var onUpload: ((URL) -> Void)?

    /// A second hook rather than a wider ``onUpload``: the Mac's browser can take a run of entries, the SFTP one a file at a time. Where it is nil the picker stays single-item rather than offering a selection whose extras would be dropped.
    var onUploadItems: (([URL]) -> Void)?

    /// Called only after the user has confirmed, and the confirmation lives here, in the one place both browsers go through, since a guard a caller can forget is not a guard.
    var onRun: ((RemoteDirectoryEntry) -> Void)?

    /// Supplied by the caller: the Mac moves things to the Trash (recoverable), an SFTP server deletes them outright.
    var deleteHint: String = String(localized: "This cannot be undone.")

    /// The three below are one capability and are passed (or absent) together.
    var onCreate: ((String, RemoteEntryKind) -> Void)?
    var onRename: ((RemoteDirectoryEntry, String) -> Void)?
    /// Called only after the user has confirmed; the confirmation lives here for the reason given on ``onRun``.
    var onDelete: ((RemoteDirectoryEntry) -> Void)?

    /// A disabled control rather than a spinner: the machine answers a change by naming the path, so two in flight would match two answers to one remembered request.
    var isChanging: Bool = false

    /// Above the list rather than replacing it, unlike ``failure``: the folder is fine and the row to retry is still on screen.
    var changeFailure: String? = nil

    /// The Mac blocks inside the listing call while macOS shows a Files-and-Folders prompt, so a permission question and a slow disk look the same. There is no API to detect the prompt, so this is a delayed guess.
    @State var waitingLongEnough = false

    /// Filtered locally: a round trip per letter would flicker behind the keyboard, and both browsers narrow the same way.
    @State var query = ""
    @State var showsImporter = false

    @State var pendingRun: RemoteDirectoryEntry?

    @State var pendingCreate: RemoteEntryKind?
    @State var nameDraft = ""

    @State var pendingRename: RemoteDirectoryEntry?
    @State var pendingDelete: RemoteDirectoryEntry?

    @FocusState var searchFocused: Bool

    static let slowReadInterval: Duration = .milliseconds(2500)

    var body: some View {
        VStack(spacing: 0) {
            header
                // On the header, not the body: SwiftUI does not reliably honour several alert modifiers on one view (the Run alert is on the body), so one alert per subtree.
                .alert(createTitle, isPresented: Binding(
                    get: { pendingCreate != nil },
                    set: { if !$0 { pendingCreate = nil } }
                )) {
                    TextField("Name", text: $nameDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Cancel", role: .cancel) { pendingCreate = nil }
                    Button("Create") {
                        if let kind = pendingCreate { onCreate?(nameDraft, kind) }
                        pendingCreate = nil
                    }
                } message: {
                    Text("It will be made in \(path ?? String(localized: "this folder")).")
                }
                .alert("Rename", isPresented: Binding(
                    get: { pendingRename != nil },
                    set: { if !$0 { pendingRename = nil } }
                )) {
                    TextField("Name", text: $nameDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Cancel", role: .cancel) { pendingRename = nil }
                    Button("Rename") {
                        if let entry = pendingRename { onRename?(entry, nameDraft) }
                        pendingRename = nil
                    }
                } message: {
                    Text(pendingRename?.name ?? "")
                }
            if let progress { progressLine(progress) }
            content
                .confirmationDialog(
                    deleteTitle,
                    isPresented: Binding(
                        get: { pendingDelete != nil },
                        set: { if !$0 { pendingDelete = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button(deleteButtonTitle, role: .destructive) {
                        if let entry = pendingDelete { onDelete?(entry) }
                        pendingDelete = nil
                    }
                    Button("Cancel", role: .cancel) { pendingDelete = nil }
                } message: {
                    Text(deleteMessage)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Only the thing being uploaded, not the whole Finder tree. Multi-select only where the caller can take more than one, so the app never silently discards a chosen file.
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: onUploadItems != nil
        ) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            if let onUploadItems {
                onUploadItems(urls)
            } else if let url = urls.first {
                onUpload?(url)
            }
        }
        // The drop (an iPad addition) is handled like the picker's result by the caller. Only where the caller can take several, else extra items would vanish.
        .dropDestination(for: URL.self) { urls, _ in
            guard let onUploadItems, !urls.isEmpty else { return false }
            onUploadItems(urls)
            return true
        }
        // Keyed to the wait itself, including one that ends in failure, which has its own message and should not be talked over.
        .task(id: isLoading) {
            waitingLongEnough = false
            guard isLoading else { return }
            try? await Task.sleep(for: Self.slowReadInterval)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { waitingLongEnough = true }
        }
        // Cleared per folder: a stale filter would hide rows for no visible reason.
        .onChange(of: path) { _, _ in query = "" }
        // The one guard between a tap and a program running on the machine, here so neither browser can forget it. Cancel is first with the cancel role; Run is not the default action.
        .alert(
            "Run this file?",
            isPresented: Binding(
                get: { pendingRun != nil },
                set: { if !$0 { pendingRun = nil } }
            ),
            presenting: pendingRun
        ) { entry in
            Button("Cancel", role: .cancel) { pendingRun = nil }
            Button("Run") {
                pendingRun = nil
                onRun?(entry)
            }
        } message: { entry in
            Text(
                """
                \(childPath(entry.name, of: path))

                It will run with your permissions on the machine this folder is on.
                """
            )
        }
    }
}
