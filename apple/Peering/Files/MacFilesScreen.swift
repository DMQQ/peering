import MacCastKit
import RemoteCore
import SwiftUI

/// The Mac's folders with no shell: the same browser as the terminal's, on a browsing scope. No shell keys or Run button, since there is no shell.
/// One page per folder, so the swipe back is one level up. The first page has no path of its own and opens where the Mac last left it.
struct MacFilesScreen: View {
    let path: String?
    /// Living inside the hub's Files tab, which owns the title, the back button and the way out.
    var embedded = false
    let push: (String) -> Void
    let close: () -> Void
    let preview: (String) -> Void

    @Environment(SessionModel.self) var model

    @State var showsHiddenFiles = false
    @State private var restoredPath: String?
    /// The folder the first page settled on, so pages pushed above it do not drag it along through the shared browser path.
    @State private var home: String?

    private var shownPath: String? { path ?? home }

    /// Nothing above the user's own folder is offered.
    private var floor: String? { AgentFolderPath.userHome(containing: shownPath ?? model.browserPath) }

    var body: some View {
        Group {
            if let id = model.browserID {
                content(id)
                    .downloadShareSheet(sessionID: id)
            } else {
                Text("Not connected to a Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ColorPalette.backdrop)
        .modifier(PushedFolderChrome(enabled: !embedded, path: shownPath, floor: floor, push: push, close: close))
        .onAppear {
            guard let id = model.browserID else { return }
            // The scope first: the Mac keeps one only for the connection that made it, and the listing that follows travels after it on the same connection.
            model.openFileScope()
            if let path {
                model.setBrowserPath(path)
                model.listDirectory(path, sessionID: id)
                return
            }
            if home == nil {
                home = model.browserPath
                if home == nil, let saved = model.rememberedFilesFolder {
                    restoredPath = saved
                    home = saved
                    model.setBrowserPath(saved)
                }
            }
            model.listDirectory(home, sessionID: id)
        }
        .onChange(of: model.browserPath) { _, new in
            if path == nil, home == nil { home = new }
        }
        // A remembered folder that is gone, renamed or no longer readable falls back to the home folder instead of leaving the browser on an error.
        .onChange(of: restoredFailure) { _, failure in
            guard failure != nil, let id = model.browserID else { return }
            restoredPath = nil
            home = nil
            model.forgetFilesFolder()
            model.setBrowserPath(nil)
            model.listDirectory(nil, sessionID: id)
        }
    }

    private var restoredFailure: String? {
        guard path == nil, let id = model.browserID, let restoredPath, home == restoredPath else { return nil }
        return model.browseFailure(restoredPath, sessionID: id)
    }

    @ViewBuilder
    private func content(_ id: UUID) -> some View {
        VStack(spacing: 0) {
            FileBrowserPanel(
                path: model.browserPath,
                directory: model.directory(shownPath, sessionID: id),
                isLoading: model.isLoadingDirectory(shownPath, sessionID: id),
                failure: model.downloadFailure(sessionID: id)
                    ?? model.uploadFailure(sessionID: id)
                    ?? model.browseFailure(shownPath, sessionID: id),
                showsHidden: showsHiddenFiles,
                onToggleHidden: { showsHiddenFiles.toggle() },
                showsBreadcrumbs: false,
                // The Mac blocks inside the listing call while macOS shows a Files-and-Folders prompt, and nothing of that reaches this phone, so the wait says what it is probably waiting for.
                waitingHint: String(localized: "Your Mac is probably asking whether Peering may open this folder. That is a normal macOS question, asked once per folder. Choose Allow on the Mac and the list appears here. Peering only reads folders you open from here."),
                progress: model.downloadProgress(sessionID: id) ?? model.folderProgress(sessionID: id),
                onCancelProgress: model.isUploading(sessionID: id) ? { model.cancelUpload(sessionID: id) } : nil,
                onOpen: { open($0, in: id) },
                onNavigate: { push($0) },
                floor: floor,
                onRevealPath: nil,
                onReload: { model.listDirectory(shownPath, sessionID: id) },
                onUpload: { model.uploadFile($0, sessionID: id) },
                onUploadItems: { model.uploadItems($0, sessionID: id) },
                onDownload: { entry in
                    let target = childPath(entry.name, of: shownPath)
                    if entry.isDirectory {
                        model.downloadFolder(target, sessionID: id)
                    } else {
                        model.downloadFile(target, sessionID: id)
                    }
                },
                onUploadInto: { model.uploadItems($0, toFolder: $1, sessionID: id) },
                onRun: nil,
                deleteHint: String(localized: "It can be put back from the Trash on your Mac."),
                onCreate: canMake
                    ? { model.createEntry($0, kind: $1, in: folder, sessionID: id) }
                    : nil,
                onRename: canMake
                    ? { model.renameEntry($0, to: $1, in: folder, sessionID: id) }
                    : nil,
                onDelete: canMake
                    ? { model.deleteEntry($0, in: folder, sessionID: id) }
                    : nil,
                isChanging: model.isChangingFile(sessionID: id),
                changeFailure: model.changeFailure(sessionID: id)
            )
        }
    }

    private var canMake: Bool { shownPath != nil }

    private var folder: String { shownPath ?? "" }

    private func open(_ entry: RemoteDirectoryEntry, in id: UUID) {
        let path = childPath(entry.name, of: shownPath)
        if entry.isDirectory {
            push(path)
        } else {
            preview(path)
        }
    }
}

/// The title, parent-folder menu, back button and Done of a folder page pushed on the stack.
private struct PushedFolderChrome: ViewModifier {
    let enabled: Bool
    let path: String?
    let floor: String?
    let push: (String) -> Void
    let close: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .navigationTitle(path.map { $0 == "/" ? "/" : ($0 as NSString).lastPathComponent } ?? String(localized: "Files"))
                .navigationBarTitleDisplayMode(.inline)
                .ancestorsMenu(of: path, floor: floor) { push($0) }
                .folderBackButton(of: path, floor: floor) { push($0) }
                .toolbarBackground(ColorPalette.backdrop, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(String(localized: "Done"), action: close)
                    }
                }
        } else {
            content
        }
    }
}
