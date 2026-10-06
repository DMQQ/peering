import MacCastKit
import RemoteCore
import SwiftUI

struct AgentFolderPicker: View {
    let title: String
    let agentID: String
    let choose: (String?) -> Void

    @Environment(SessionModel.self) var model

    @State private var query = ""
    @State private var chosen = false
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
        // Cleared on the way into the next folder: a filter that follows you down hides folders you have not seen.
        .onChange(of: picker.path) { _, _ in
            query = ""
            searchFocused = false
        }
    }

    // MARK: - Header

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
                    if picker.path == picker.startPath, !recents.isEmpty {
                        recentSection
                    }
                }
            }
        }
        // Padding for the floating button goes on the content end only: padding the scroll view shrank it and left a dead band.
        .contentMargins(.bottom, Self.floatingClearance, for: .scrollContent)
        .scrollBounceBehavior(.basedOnSize)
    }

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

    private static let floatingClearance: CGFloat = 70

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

    private var isAtHome: Bool {
        picker.path == picker.startPath
    }

    private var hairline: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
    }
}
