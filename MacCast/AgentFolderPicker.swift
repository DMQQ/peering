import MacCastKit
import RemoteCore
import SwiftUI

/// Where a chat should work, asked before it starts.
///
/// The folder is the agent's whole world: it decides what the model can see and change, so it is
/// chosen deliberately rather than defaulted. Drawn as the file browser is drawn, because it is
/// the same task: the same rows, the same breadcrumbs, the same walk one folder per tap. It is
/// deliberately not the browser itself, which carries previews and write operations this has no
/// business offering mid-start.
struct AgentFolderPicker: View {
    /// What the screen is called, which is the agent for a chat and the thing being made for a
    /// shell: the same walk of the same folders, asking the same question about where.
    let title: String
    /// Whose recent folders are offered. The chat agents each keep their own; a shell keeps one
    /// list of its own under a name of its own.
    let agentID: String
    let choose: (String?) -> Void

    @Environment(SessionModel.self) var model

    /// What the user is looking for among the folders. Filtered here rather than asked of the
    /// Mac, the same way the file browser filters its own lists: the listing is already in hand,
    /// and a round trip per letter typed is a list that flickers behind the keyboard.
    @State private var query = ""
    @State private var chosen = false
    /// Whether folders whose names begin with a dot are listed. Filtered on this side, so both
    /// browsers behave the same way about it. Off to start with, because on a Mac that is usually
    /// what "the folders in this folder" means to a person.
    @State private var showsHiddenFolders = false
    @FocusState private var searchFocused: Bool

    private var picker: AgentPickerState { model.agentPicker }

    private var segments: [(title: String, path: String)] {
        guard let path = picker.path, path.hasPrefix("/") else { return [] }
        var result: [(title: String, path: String)] = [("/", "/")]
        var walked = ""
        for component in path.split(separator: "/") {
            walked += "/" + component
            result.append((String(component), walked))
        }
        return result
    }

    private var folders: [RemoteDirectoryEntry] {
        picker.entries
            .filter(\.isDirectory)
            .filter { showsHiddenFolders || !$0.name.hasPrefix(".") }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var recents: [AgentFolderHistory.Entry] {
        AgentFolderHistory.load()
            .filter { $0.agentID == agentID && $0.path != picker.path }
            .prefix(3)
            .map { $0 }
    }

    var body: some View {
        // The button floats over the list rather than sitting in a bar under it: the list runs on
        // behind the glass, so the last folder is never pushed off the bottom of the screen by a
        // strip of chrome, and the one thing this screen wants the user to do stands out from it.
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header
                list
            }
            floatingAction
        }
        .background(ColorPalette.backdrop)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            chosen = false
            if picker.path == nil, !picker.isLoading {
                model.browseAgentFolder(nil)
            }
        }
        // Typed in one folder, cleared on the way into the next: a filter that follows you down
        // the tree hides folders you have never seen and looks like a folder that is not there.
        .onChange(of: picker.path) { _, _ in
            query = ""
            searchFocused = false
        }
    }

    // MARK: - Header

    /// Where the walk is, drawn as the browser draws it: monospaced segments, every one a way
    /// back, the last one written rather than made tappable.
    private var header: some View {
        VStack(spacing: 0) {
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(Array(segments.enumerated()), id: \.element.path) { index, segment in
                            if index > 0 {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            if index == segments.count - 1 {
                                Text(segment.title)
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(ColorPalette.ink)
                                    .lineLimit(1)
                            } else {
                                Button { model.browseAgentFolder(segment.path) } label: {
                                    Text(segment.title)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                }
                .onAppear { reader.scrollTo(segments.last?.path, anchor: .trailing) }
                .onChange(of: picker.path) { _, _ in
                    withAnimation(Motion.settle) { reader.scrollTo(segments.last?.path, anchor: .trailing) }
                }
            }
            .overlay(alignment: .trailing) {
                if picker.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .padding(.trailing, 14)
                }
            }
            // The same two controls the file browser's header carries, in the same band under the
            // path: a field for finding one folder among many, and the eye that says whether the
            // dot ones count as folders.
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)

                    TextField("Filter these names", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(ColorPalette.ink)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($searchFocused)
                        .submitLabel(.done)
                        .onSubmit { searchFocused = false }

                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.tertiary)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear the filter")
                    }
                }
                .padding(.leading, 11)
                .padding(.trailing, query.isEmpty ? 11 : 5)
                .frame(height: 32)
                .background(Color.white.opacity(0.07), in: Capsule())

                Button { showsHiddenFolders.toggle() } label: {
                    Image(systemName: showsHiddenFolders ? "eye" : "eye.slash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(showsHiddenFolders ? ColorPalette.accent : Color.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsHiddenFolders ? "Hide hidden folders" : "Show hidden folders")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 9)

            // What choosing this folder means, said once and quietly. It lives here rather than
            // under the button because the button floats over the list, and a sentence over a
            // scrolling list is a sentence nobody can read.
            Text("The agent can read and change files in the folder you choose.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 9)
        }
        .background(Color.white.opacity(0.05))
        .overlay(alignment: .bottom) { hairline }
    }

    // MARK: - List

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                if picker.path == nil, picker.isLoading {
                    Color.clear.frame(height: 1)
                } else {
                    if let failure = picker.failure {
                        Text(failure)
                            .font(.footnote)
                            .foregroundStyle(ColorPalette.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        Controls.divider
                    }
                    if let parent = parentPath {
                        upRow(parent)
                        Controls.divider
                    }
                    if folders.isEmpty, !picker.isLoading {
                        Text(query.isEmpty
                            ? "This folder has no folders inside it."
                            : "No folder here matches \u{201C}\(query)\u{201D}.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    }
                    ForEach(Array(folders.enumerated()), id: \.element.name) { index, entry in
                        if index > 0 { Controls.divider }
                        row(entry)
                    }
                    // Only where the walk started: deeper in, a shortcut out of the folder being
                    // looked at is a second way to answer a question the user has not asked yet.
                    if picker.path == picker.startPath, !recents.isEmpty {
                        recentSection
                    }
                }
            }
        }
        // Room for the floating button at the end of the content only. Padding the scroll view
        // itself shrank it and left a dead band under the list, which the button sat in.
        .contentMargins(.bottom, Self.floatingClearance, for: .scrollContent)
        .scrollBounceBehavior(.basedOnSize)
    }

    /// One folder, drawn as the file browser draws one: the same glyph, the same two lines, the
    /// same chevron on the other side of the tap.
    private func row(_ entry: RemoteDirectoryEntry) -> some View {
        Button {
            guard let path = picker.path else { return }
            model.browseAgentFolder(path + "/" + entry.name)
        } label: {
            HStack(spacing: 11) {
                Controls.icon(entry.isSymlink ? "folder.badge.questionmark" : "folder")
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(ColorPalette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(entry.isSymlink ? "Folder, through a link" : "Folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 10)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 16)
            .padding(.trailing, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The row out of this folder, as the browser writes it.
    private func upRow(_ parent: String) -> some View {
        Button {
            model.browseAgentFolder(parent)
        } label: {
            HStack(spacing: 11) {
                Controls.icon("arrow.up.left")
                VStack(alignment: .leading, spacing: 2) {
                    Text("..")
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .foregroundStyle(ColorPalette.ink)
                    Text("Up one level")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 16)
            .padding(.trailing, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var recentSection: some View {
        VStack(spacing: 0) {
            HStack {
                Controls.sectionLabel("Recent folders", systemImage: "clock.arrow.circlepath")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 6)
            ForEach(Array(recents.enumerated()), id: \.element.path) { index, entry in
                if index > 0 { Controls.divider }
                Button {
                    pick(entry.path)
                } label: {
                    HStack(spacing: 11) {
                        Controls.icon("clock.arrow.circlepath")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.path)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(ColorPalette.ink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("Work here again")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 10)
                        Image(systemName: "arrow.turn.down.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 16)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Action bar

    /// The one button that leaves this screen: use what is on it. The trust sentence sits with
    /// it, because starting an agent in a folder is granting the agent that folder.
    /// How much room the list leaves at its end: the button's own height and its margin, and no
    /// more. Padding it further is a band of nothing above the button when the list is scrolled to
    /// the bottom, which reads as a container rather than as something floating.
    private static let floatingClearance: CGFloat = 70

    /// The one way out of this screen: the folder on it, floating.
    ///
    /// The button alone, lifted off the page by a shadow rather than boxed in a card: it is the
    /// only thing the screen asks for, and a container around one control is a second edge saying
    /// nothing.
    private var floatingAction: some View {
        Button {
            pick(picker.path)
        } label: {
            Text(isAtHome ? "Use the home folder" : "Use this folder")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ColorPalette.onInk)
                .padding(.horizontal, 26)
                .frame(height: 50)
                .background(Capsule().fill(ColorPalette.ink))
                .contentShape(Capsule())
        }
        .buttonStyle(RailButtonStyle(scale: 0.96))
        .disabled(picker.path == nil && picker.isLoading)
        .shadow(color: .black.opacity(0.55), radius: 22, y: 10)
        .padding(.bottom, 12)
    }

    // MARK: - Paths

    /// Once, because the screen stays up until the Mac answers and a second tap would start a
    /// second one.
    private func pick(_ directory: String?) {
        guard !chosen else { return }
        chosen = true
        choose(directory)
        // A Mac that never answers must not leave this screen unable to choose again.
        Task {
            try? await Task.sleep(for: .seconds(6))
            chosen = false
        }
    }

    private var parentPath: String? {
        guard let path = picker.path, path.count > 1 else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    /// The home folder, learned rather than assumed: the first answer from the Mac is what home
    /// is, because only the Mac knows.
    private var isAtHome: Bool {
        picker.path == picker.startPath
    }

    private var hairline: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
    }
}
