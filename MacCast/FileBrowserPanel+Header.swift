import RemoteCore
import SwiftUI
import UniformTypeIdentifiers
import MacCastKit
import os

extension FileBrowserPanel {
    // MARK: - The three dialogs

    var createTitle: String {
        pendingCreate == .folder ? "New Folder" : "New File"
    }

    /// The emptiness check reads the raw listing, not the visible rows: a folder holding only hidden files draws empty and is not.
    var deleteIsRecursive: Bool {
        guard let directory, pendingDelete?.isDirectory == true else { return false }
        return !(directory.entries.isEmpty && !directory.isTruncated)
    }

    var deleteTitle: String {
        guard let entry = pendingDelete else { return "Delete" }
        return deleteIsRecursive
            ? String(localized: "Delete “\(entry.name)” and everything in it?")
            : String(localized: "Delete “\(entry.name)”?")
    }

    var deleteButtonTitle: String { deleteIsRecursive ? String(localized: "Delete All") : "Delete" }

    var deleteMessage: String {
        let scope = pendingDelete?.isDirectory == true
            ? String(localized: "The folder and everything inside it will go.")
            : String(localized: "The file will go.")
        return scope + " " + deleteHint
    }

    // MARK: - Header

    @ViewBuilder
    var header: some View {
        if showsBreadcrumbs {
            breadcrumbs
                .background(Color.white.opacity(0.05))
                // Only along the bottom: the tab strip draws the seam above, and a second hairline would read as two rules.
                .overlay(alignment: .bottom) { hairline }
        }
    }

    /// The filter is always on screen: a control that has to be found does not get used, and a folder of two hundred rows needs it.
    /// The create control is a menu because a third circle would squeeze the filter. These controls sit beside the field, not in it, because they change the machine rather than the view.
    var bottomBar: some View {
        FolderBrowserBar(
            prompt: String(localized: "Search this folder"),
            query: $query,
            showsHidden: Binding(get: { showsHidden }, set: { _ in onToggleHidden?() }),
            searchFocused: $searchFocused
        ) {
            // On the left, away from the send button: two round buttons side by side read as one control.
            if onCreate != nil {
                Menu {
                    Button("New Folder", systemImage: "folder.badge.plus") {
                        beginCreate(.folder)
                    }
                    Button("New File", systemImage: "doc.badge.plus") {
                        beginCreate(.file)
                    }
                } label: {
                    chrome("plus")
                }
                // Disabled rather than hidden while a change is in flight: a control vanishing under the finger reads as a bug.
                .disabled(isChanging)
                .accessibilityLabel("New file or folder")
            }
        } actions: {
            if onUpload != nil {
                // The button rather than the row, dimmed with the plan's name on its corner for plans without file transfer: a free user who never sees the control never learns the app can do it. Tapping opens the plans.
                PlanLocked(
                    capability: .fileTransfer,
                    title: "Send a file or a folder here",
                    diameter: 48
                ) {
                    Button { showsImporter = true } label: {
                        chrome("arrow.up.to.line")
                    }
                    .buttonStyle(RailButtonStyle(scale: 0.9))
                    .disabled(isChanging)
                    .accessibilityLabel("Send a file or a folder here")
                }
            }
        }
    }

    func chrome(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(ColorPalette.ink)
            .frame(width: 48, height: 48)
            .glassSurface(in: Circle())
            .contentShape(Circle())
    }

    /// The collision check runs against the raw listing, not the visible rows: a hidden `New Folder` would otherwise leave the name looking free and the machine would refuse it.
    func beginCreate(_ kind: RemoteEntryKind) {
        let base = kind == .folder ? "New Folder" : "New File"
        let suffix = kind == .folder ? "" : ".txt"
        nameDraft = RemoteFileName.available(
            base: base,
            extension: suffix,
            among: directory?.entries.map(\.name) ?? []
        )
        pendingCreate = kind
    }

    // MARK: - Breadcrumbs

    var breadcrumbs: some View {
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
                            Button { onNavigate(segment.path) } label: {
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
            // The end of the path is where the user is; the scroll starts at the root, the wrong end.
            .onAppear { reader.scrollTo(segments.last?.path, anchor: .trailing) }
            .onChange(of: path) { _, _ in
                withAnimation(Motion.settle) { reader.scrollTo(segments.last?.path, anchor: .trailing) }
            }
        }
        // The spinner sits outside the scroller so a deep path cannot push it off screen.
        .overlay(alignment: .trailing) {
            if isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .padding(.trailing, 14)
            }
        }
    }

    var segments: [(title: String, path: String)] {
        guard let path, path.hasPrefix("/") else { return [] }
        var result: [(title: String, path: String)] = [("/", "/")]
        var walked = ""
        for component in path.split(separator: "/") {
            walked += "/" + component
            result.append((String(component), walked))
        }
        return result
    }
}
