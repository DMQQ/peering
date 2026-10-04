import RemoteCore
import SwiftUI
import UniformTypeIdentifiers
import MacCastKit
import os

// `childPath` moved to `RemoteCore`, alongside `ShellPath.quoted`, when the SSH browser turned
// out to need the same join for a different reason: resolving a symbolic link means naming the
// thing on the other end of it. The rule is unchanged and this file still calls it unqualified.

/// A folder on the Mac, as a list.
///
/// Draws what it is given and asks for nothing: every tap is a callback, and the panel holds no
/// session, no path of its own and no cache. ``TerminalPanel`` owns all of that, which is what
/// lets this be the same view for the two browsers the app is going to have — the Mac this phone
/// is casting to, and the server the SSH terminal is on — with the difference between them living
/// in whoever answers the callbacks.
///
/// The list is drawn on the terminal's own black rather than on a card, and that is deliberate.
/// This panel is not a screen of its own: it is what the terminal shows instead of its output for
/// as long as the user is looking at folders, so it keeps the terminal's shape — flat bands, a
/// rule between them, glyphs in the app's own tile — and takes only the parts of the settings
/// vocabulary that survive being put on black.
struct FileBrowserPanel: View {
    /// The folder being shown, and `nil` while the Mac's home folder is still being resolved.
    let path: String?
    /// What the Mac sent for it, if anything has arrived yet. A folder already in hand is shown
    /// while its next copy is on the way, which is what makes stepping in and back out instant.
    let directory: RemoteDirectory?
    let isLoading: Bool
    let failure: String?
    /// Whether names beginning with a dot are listed. Filtered here rather than on the Mac, so
    /// that both browsers behave the same way about it in phase two.
    let showsHidden: Bool

    /// What to say when a listing takes long enough that waiting is no longer the whole story.
    ///
    /// Supplied by whoever answers the callbacks, because only they know what a slow read means on
    /// their side. On the Mac it is almost always the system asking the user a question, and on a
    /// server it is the server or the network. `nil` says nothing, which is what a browser with no
    /// such story to tell should do.
    ///
    /// `var` rather than `let` for the default, which is a Swift rule rather than a preference: a
    /// `let` with an initial value is not part of the memberwise initialiser at all, so a call
    /// site passing one would be told it had an extra argument.
    var waitingHint: String? = nil

    /// What a long job is doing, drawn between the path bar and the list. `nil` draws nothing.
    ///
    /// It exists for the folder upload, which is a run of hundreds of operations the user cannot
    /// see, over a panel that otherwise looks exactly as it did before they started. `nil` is right
    /// for every other state this panel has: a read has its own spinner and a write shows up as the
    /// entry appearing in the list.
    ///
    /// **A sentence rather than a bar.** The entries are not all the same size, so a bar filled from
    /// the count would move at a speed with nothing to do with the bytes, and an indicator that
    /// lies about how much is left is worse than one that only says where it has got to.
    var progress: String? = nil

    /// A folder or file was tapped.
    var onOpen: (RemoteDirectoryEntry) -> Void
    /// Go to an absolute path: a breadcrumb, or the row that steps up a level.
    var onNavigate: (String) -> Void
    /// Put a path in the terminal's command line rather than opening it.
    var onRevealPath: (String) -> Void
    /// Ask for the current folder again.
    var onReload: () -> Void

    /// Send a file the user picked to the folder on screen.
    ///
    /// Optional rather than a closure that might do nothing, because the button is drawn from
    /// whether this is here: a control that appears and then silently does nothing is worse than one
    /// that was never offered. Both browsers pass one now; what is left for the `nil` to mean is a
    /// shell that has ended, where there is nothing left to send a file down.
    var onUpload: ((URL) -> Void)?

    /// Several things at once: what a drop carries, and what a multi-item pick gives.
    ///
    /// **A second hook rather than a wider ``onUpload``, because the browsers differ in what they
    /// can take.** The Mac's browser sends a run of entries and can be handed anything; the SFTP
    /// one sends a file at a time and has nowhere to put a second. A caller that has nowhere to put
    /// them leaves this `nil`, and the picker stays single-item rather than offering a selection it
    /// would silently drop the extras of.
    ///
    /// Where it is set, it is what the picker and the drop both call, and ``onUpload`` is left for
    /// the single-item path.
    var onUploadItems: (([URL]) -> Void)?

    /// Run an executable file, which is offered as a button on the row itself.
    ///
    /// Optional in the same way ``onUpload`` is, and absent for the same kind of reason: a shell
    /// that has ended has nothing to type into. **It is called only after the user has confirmed**,
    /// and the confirmation lives here rather than in either caller — this is the one place both
    /// browsers go through, and a guard a caller can forget is not a guard.
    ///
    /// Nothing about this is a new privilege. What the button sends is a line typed into a shell
    /// the user already has, which is exactly what a terminal is for; what it adds is that the
    /// thing being typed is a file they can see rather than one they have to spell.
    var onRun: ((RemoteDirectoryEntry) -> Void)?

    /// What the delete confirmation says will become of what goes.
    ///
    /// Supplied by the caller because it is the one part of the sentence the panel cannot know and
    /// the user cannot guess: the Mac moves things to the Trash and they can be put back, while an
    /// SFTP server deletes them outright. Two machines, two very different weights on one word, and
    /// the weight is the point of asking. Declared here with the capabilities rather than with the
    /// state below, because it is part of what the caller is offering.
    var deleteHint: String = String(localized: "This cannot be undone.")

    /// Make something in the folder on screen.
    ///
    /// Optional in the same way, and `nil` means the same thing: a shell that has ended cannot be
    /// asked to change anything, and a New Folder button that opens a dialog and then fails is
    /// worse than one that is not there. The three below are one capability in three shapes, so
    /// they are passed together and are meant to be absent together.
    var onCreate: ((String, RemoteEntryKind) -> Void)?
    /// Give something on screen a new name.
    var onRename: ((RemoteDirectoryEntry, String) -> Void)?
    /// Remove something on screen, and everything inside it if it is a folder.
    ///
    /// Called only after the user has confirmed, and **the confirmation lives here** rather than in
    /// either caller — this is the one place both browsers go through, and a guard a caller can
    /// forget is not a guard. Same reasoning as ``onRun``.
    var onDelete: ((RemoteDirectoryEntry) -> Void)?

    /// Whether a change asked for through this browser is still in the air.
    ///
    /// Drawn as a disabled control rather than as a spinner, because the operation is quick and the
    /// thing that matters is not being able to start a second one: the machine answers a change by
    /// naming the path it was given, so two in flight would be two answers matched against one
    /// remembered request.
    var isChanging: Bool = false

    /// Why the last change did not happen, drawn above the list.
    ///
    /// **Above rather than in place of.** A failure here is not a folder that could not be read —
    /// that is ``failure``, and it replaces the list because there is nothing to show. This is the
    /// opposite: the folder is fine, one thing in it did not happen, and the row the user is most
    /// likely to try again on is still on screen behind this sentence.
    var changeFailure: String? = nil

    /// Whether the current wait has lasted long enough to be explained.
    ///
    /// The Mac blocks *inside* the listing call while macOS shows a Files-and-Folders prompt, so
    /// from here a permission question and a slow disk are the same thing: a request that has not
    /// answered. There is no API that says "a prompt is on screen over there", and the honest
    /// thing is therefore a guess with a delay on it — long enough that a listing which was
    /// merely quick has already arrived, short enough that nobody sits through it twice.
    @State var waitingLongEnough = false

    /// What the user is looking for, if they have said.
    ///
    /// Filtered here rather than asked of the machine, and for the reason the hidden-file rule is
    /// filtered here too: a folder is already in hand, and a second round trip for every letter
    /// typed would be a listing that flickers behind the keyboard. It also means both browsers
    /// narrow the same way, which they would not if one of them asked a server to.
    @State var query = ""
    /// Whether the system's file picker is up. See ``searchField`` for the button that raises it.
    @State var showsImporter = false

    /// The file a Run button was tapped on, waiting on the alert.
    ///
    /// Held rather than acted on, because the whole point of the confirmation is that the tap is
    /// not the decision. See ``onRun``.
    @State var pendingRun: RemoteDirectoryEntry?

    /// What a New File or New Folder tap is asking for, waiting on the name.
    ///
    /// The kind is held rather than two separate flags, because the two differ only in the noun and
    /// the default name and every other line of the dialog is the same one.
    @State var pendingCreate: RemoteEntryKind?
    /// The name in the create or rename field, as it is typed.
    @State var nameDraft = ""

    /// The row a Rename tap is about, waiting on a new name.
    @State var pendingRename: RemoteDirectoryEntry?
    /// The row a Delete tap is about, waiting on the confirmation.
    ///
    /// Held rather than acted on, for the reason ``pendingRun`` is: the tap that offers to delete
    /// is not the decision to delete, and a recursive delete of somebody's folder is not a thing to
    /// do on a mis-tap.
    @State var pendingDelete: RemoteDirectoryEntry?

    /// A real `@FocusState`, unlike the terminal's own command field, and it is the same fact
    /// that makes that one a plain flag: this is a SwiftUI `TextField` and claims its focus
    /// through a `.focused()` modifier, so SwiftUI and UIKit agree about who is first responder.
    @FocusState var searchFocused: Bool

    static let slowReadInterval: Duration = .milliseconds(2500)

    var body: some View {
        VStack(spacing: 0) {
            header
                // **On the header rather than on the body, and that is not decoration.** SwiftUI
                // does not reliably honour several alert modifiers stacked on one view — the Run
                // alert below is already on the body, and a second one there risks silently never
                // presenting at all. One alert per subtree is the arrangement that works, so the
                // two name dialogs live here and the confirmation lives on `content`.
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
                    Text("It will be made in \(path ?? "this folder").")
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
                    // The name it has now, so a user who arrived here from a context menu on a long
                    // row can see which of several similar names they are changing.
                    Text(pendingRename?.name ?? "")
                }
            // Under the path bar and above the list, so it belongs to the folder rather than to
            // any row in it. See ``progress``.
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
                    // What the machine on the other end does with it, which is the one thing the
                    // user needs to know and cannot guess: the Mac moves it to the Trash and it can
                    // be put back; an SFTP server deletes it, and there is nowhere to put it back
                    // from. The sentence is the caller's because only the caller knows which
                    // machine this browser is talking to.
                    Text(deleteMessage)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Only the thing being uploaded, not the whole Finder tree: this is one file into one
        // folder, and a picker that offers everything is a picker that makes the user work out
        // which of the options they have already found is the one that sends it.
        //
        // **Multi-select only where the caller can take more than one.** Choosing several is an
        // offer to send several, and a picker that allowed the selection while the browser could
        // only send the first would be the app quietly discarding what the user just chose.
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
        // **The drop, which is the whole of what an iPad adds here.** A file or a folder dragged
        // in from Files is the same thing the picker hands back and is treated the same way: the
        // security scope, the folder-or-file decision and the run are all the caller's, and there
        // is nothing about arriving by drag that changes what has to happen to it.
        //
        // Only where a caller can take several, for the reason the picker is single-item without
        // one: a drop carrying four items into a browser that can send one is three silent
        // disappearances.
        .dropDestination(for: URL.self) { urls, _ in
            guard let onUploadItems, !urls.isEmpty else { return false }
            onUploadItems(urls)
            return true
        }
        // Keyed to the wait itself, so the clock starts when a request goes out and the flag is
        // cleared the moment one comes back — including a wait that ends in a failure, which has
        // its own thing to say and should not be talked over.
        .task(id: isLoading) {
            waitingLongEnough = false
            guard isLoading else { return }
            try? await Task.sleep(for: Self.slowReadInterval)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { waitingLongEnough = true }
        }
        // Looking for something is looking for it *here*. A filter left over from the last folder
        // would arrive in the new one as rows that are missing for no reason on screen — the same
        // fault as a search field that keeps its text after the thing it searched has gone.
        .onChange(of: path) { _, _ in query = "" }
        // The one guard between a tap and a program running on somebody's machine, and it is here
        // rather than in either browser so that neither of them can be the one that forgot it.
        // Cancel is first and takes the cancel role, so the escape route is the one the system
        // wires to a stray dismissal; Run is deliberately not the default action.
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
