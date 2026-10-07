import MacCastKit
import RemoteCore
import SwiftUI

struct AgentFolderPicker: View {
    let title: String
    let agentID: String
    /// Nil is the Mac's home folder.
    let directory: String?
    /// Pushes a page for a folder.
    let open: (String) -> Void
    let choose: (String?) -> Void

    @Environment(SessionModel.self) var model

    /// This page's own listing: the model keeps one, which the next page overwrites.
    @State private var shown = AgentPickerState()
    @State private var awaiting = false
    @State private var hasLoaded = false
    @State private var query = ""
    @State private var chosen = false
    @State private var showsHiddenFolders = false
    @FocusState private var searchFocused: Bool

    private var picker: AgentPickerState {
        var state = shown
        state.isLoading = awaiting
        return state
    }

    private func request() {
        awaiting = true
        model.browseAgentFolder(directory)
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
        list
        .safeAreaInset(edge: .bottom, spacing: 0) {
            FolderBrowserBar(
                prompt: String(localized: "Search in \(currentName)"),
                location: picker.path.map { AgentFolderPath.display($0, home: model.agentPicker.startPath) },
                query: $query,
                showsHidden: $showsHiddenFolders,
                isLoading: picker.isLoading,
                searchFocused: $searchFocused
            ) { useButton }
        }
        .ancestorsMenu(of: picker.path) { open($0) }
        .background(ColorPalette.backdrop)
        .navigationTitle(shown.path.map(AgentFolderPath.name(of:)) ?? title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            chosen = false
            // Coming back from a deeper page, the model holds that page's listing, so this one asks again and shows what it had meanwhile.
            if !hasLoaded || model.agentPicker.path != shown.path { request() }
        }
        .onChange(of: model.agentPicker.isLoading) { _, loading in
            guard awaiting, !loading else { return }
            shown = model.agentPicker
            awaiting = false
            hasLoaded = true
        }
    }

    // MARK: - List

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                if awaiting, let note = model.agentPicker.waitingNote {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "desktopcomputer")
                            .foregroundStyle(.secondary)
                        Text(note)
                            .foregroundStyle(.white.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    Controls.divider
                }
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
                    if picker.path == picker.startPath, !recents.isEmpty {
                        recentSection
                    }
                    Text(verbatim: picker.path ?? "")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                    Text("The agent can read and change files in the folder you choose.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 2)
                        .padding(.bottom, 14)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
    }

    private func row(_ entry: RemoteDirectoryEntry) -> some View {
        Button {
            guard let path = picker.path else { return }
            open((path == "/" ? "" : path) + "/" + entry.name)
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

    private func upRow(_ parent: String) -> some View {
        Button {
            open(parent)
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

    private var currentName: String {
        shown.path.map(AgentFolderPath.name(of:)) ?? title
    }

    private var useButton: some View {
        Button {
            pick(picker.path)
        } label: {
            Text("Use")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ColorPalette.onInk)
                .padding(.horizontal, 22)
                .frame(height: 48)
                .background(Capsule().fill(ColorPalette.ink))
                .contentShape(Capsule())
        }
        .buttonStyle(RailButtonStyle(scale: 0.95))
        .disabled(picker.path == nil && picker.isLoading)
        .accessibilityLabel(isAtHome ? "Use the home folder" : "Use this folder")
    }

    // MARK: - Paths

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
        AgentFolderPath.parent(of: picker.path)
    }

    private var isAtHome: Bool {
        picker.path == picker.startPath
    }
}
