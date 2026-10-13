import PeeringKit
import PhotosUI
import RemoteCore
import SwiftUI
import UniformTypeIdentifiers

struct AgentChatScreen: View {
    @State var currentID: UUID

    init(sessionID: UUID) {
        _currentID = State(initialValue: sessionID)
    }

    @Environment(SessionModel.self) var model
    @Environment(\.dismiss) var dismiss

    @State var drafts: [UUID: String] = [:]
    @State var expandedTools: Set<UUID> = []
    @State var pendingClose: RemoteAgentSession?
    @State var renamingID: UUID?
    @State var renameText = ""
    @State var answering: AgentApproval?
    @State var openedSubagent: AgentSubagentSelection?
    /// A chat whose history never arrived (an older Mac), so it shows as empty instead of loading for ever.
    @State private var gaveUpLoading: UUID?
    @State var typingModelFor: UUID?
    @State var modelText = ""
    @State var showsAttachPicker = false
    @State var showsPhotoPicker = false
    @State var pickedPhoto: PhotosPickerItem?
    @State var attaching: Attachment?
    @State var attached: [UUID: [Attachment]] = [:]
    @State var stickToBottom = true
    @FocusState var composerFocused: Bool
    @State var showsUsage = false
    @State var showsPreview = false
    @State var showsChanges = false

    var session: RemoteAgentSession? {
        model.agentSessions.first { $0.id == currentID }
    }

    var body: some View {
        Group {
            if let session {
                VStack(spacing: 0) {
                    // One chat has nothing to switch to; its close and rename are in More.
                    if model.agentSessions.count > 1 { tabStrip }
                    content(session)
                }
            } else if model.phase != .ready {
                // Opened from a card while the Mac is still being reached: the chat is there once the list arrives.
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ended
            }
        }
        .background(ColorPalette.backdrop)
        .analyticsScreen(.agentChat)
        .navigationTitle(session?.title ?? String(localized: "Chat"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(ColorPalette.backdrop, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .sheet(isPresented: $showsUsage) {
            AgentUsageSheet(sessionID: currentID)
        }
        .sheet(isPresented: $showsPreview) {
            AgentPreviewSheet()
        }
        .sheet(isPresented: $showsChanges) {
            AgentChangesScreen(sessionID: currentID)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let session {
                    VStack(spacing: 1) {
                        Text(agentName(session))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(ColorPalette.ink)
                            .lineLimit(1)
                        Text(session.directory)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if let session { moreMenu(session) }
            }
            // No keyboard accessory bar: with the composer on the bottom safe-area inset the bar's height is counted twice and the field floats a row too high.
        }
        .terminalEndPrompt(
            name: pendingClose?.title ?? "",
            detail: String(localized: "The agent stops working on your Mac. The Mac and the rest of the chats are left alone."),
            isPresented: Binding(
                get: { pendingClose != nil },
                set: { if !$0 { pendingClose = nil } }
            ),
            onEnd: {
                guard let session = pendingClose else { return }
                model.endAgentSession(session.id)
                pendingClose = nil
                dismiss()
            }
        )
        .onAppear {
            model.selectedAgentSessionID = currentID
            model.ensureAgentHistory(currentID)
            model.prefetchAgentChanges(currentID)
            InAppBanner.shared.onScreen = .chat(currentID)
            model.noteOpenedChat(currentID)
            seedDraftIfNew()
        }
        .onChange(of: session?.transcript.state) { old, new in
            if new == .idle, old == .working { model.prefetchAgentChanges(currentID) }
        }
        .onDisappear {
            InAppBanner.shared.leave(.chat(currentID))
            model.closeAgentSessionIfUnused(currentID)
        }
        .onChange(of: InAppBanner.shared.openRequest) { _, target in
            guard case .chat(let id) = target, id != currentID, model.agentSessions.contains(where: { $0.id == id }) else { return }
            currentID = id
        }
        .onChange(of: currentID) { _, id in
            model.selectedAgentSessionID = id
            model.ensureAgentHistory(id)
            model.prefetchAgentChanges(id)
            InAppBanner.shared.onScreen = .chat(id)
        }
        .onChange(of: session?.transcript.pendingApprovals.first?.id, initial: true) { _, id in
            guard let id else {
                answering = nil
                return
            }
            if answering?.id != id, let approval = session?.transcript.pendingApprovals.first {
                answering = approval
            }
        }
        .onChange(of: model.agentSessions.map(\.id)) { _, ids in
            guard !ids.contains(currentID) else { return }
            if let next = ids.first {
                currentID = next
            } else {
                dismiss()
            }
        }
        .alert("Model", isPresented: Binding(
            get: { typingModelFor != nil },
            set: { if !$0 { typingModelFor = nil } }
        )) {
            TextField("Model name", text: $modelText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) { typingModelFor = nil }
            Button("Use") {
                if let id = typingModelFor {
                    let typed = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.setAgentModel(typed.isEmpty ? nil : typed, in: id)
                }
                typingModelFor = nil
            }
        } message: {
            Text("Whatever this Mac's agent accepts, exactly as you would type it there.")
        }
        .alert("Rename", isPresented: Binding(
            get: { renamingID != nil },
            set: { if !$0 { renamingID = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingID = nil }
            Button("Save") {
                if let id = renamingID {
                    model.renameAgentSession(id, to: renameText.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                renamingID = nil
            }
        }
    }

    private func agentName(_ session: RemoteAgentSession) -> String {
        TerminalAgent.all.first { $0.id == session.agentID }?.name ?? session.title
    }

    /// The composer is a bottom inset rather than the end of a stack, so the keyboard pushes it up instead of covering it.
    @ViewBuilder
    private func content(_ session: RemoteAgentSession) -> some View {
        ZStack {
            switch AgentChatPhase.of(
                transcriptIsEmpty: session.transcript.isEmpty,
                isLoaded: session.isLoaded,
                gaveUpLoading: gaveUpLoading == session.id
            ) {
            case .loading:
                // The empty placeholder here said the conversation was gone while it was still on its way.
                AgentHistoryLoading()
                    .transition(.opacity)
                    .task(id: session.id) {
                        try? await Task.sleep(for: .seconds(8))
                        if !session.isLoaded { gaveUpLoading = session.id }
                    }
            case .empty:
                emptyChat(session)
                    .transition(.opacity)
            case .conversation:
                AgentChatTranscript(
                    session: session,
                    expandedTools: $expandedTools,
                    stickToBottom: $stickToBottom,
                    canSend: true,
                    queued: model.agentQueue(for: session.id),
                    unqueue: { model.removeQueuedAgentPrompt(at: $0, in: session.id) },
                    resend: { text in
                        stickToBottom = true
                        model.sendAgentPrompt(text, to: session.id)
                    },
                    review: { answering = $0 },
                    openSubagent: { openedSubagent = AgentSubagentSelection(id: $0) }
                )
                .transition(.opacity)
            }
        }
        .animation(Motion.settle, value: session.transcript.isEmpty)
        .animation(Motion.settle, value: mentionQuery(session) != nil)
        .animation(Motion.settle, value: slashItems(session) != nil)
        .onChange(of: AgentSlash.query(drafts[session.id] ?? "") != nil, initial: true) { _, active in
            guard active, let id = model.browserID else { return }
            for folder in AgentSlash.folders(project: session.directory, agentID: session.agentID) {
                model.listDirectory(folder, sessionID: id)
            }
        }
        .onChange(of: mentionQuery(session)?.folder(in: session.directory), initial: true) { _, folder in
            guard let folder, let id = model.browserID else { return }
            model.listDirectory(folder, sessionID: id)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if !session.transcript.runningSubagents.isEmpty {
                    AgentSubagentStrip(running: session.transcript.runningSubagents) {
                        openedSubagent = AgentSubagentSelection(id: $0)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if attaching != nil || !(attached[session.id] ?? []).isEmpty {
                    AgentAttachmentTray(items: attached[session.id] ?? [], uploading: attaching) { id in
                        attached[session.id]?.removeAll { $0.id == id }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                // Hints take the place of the chips, which they cover rather than sit above.
                if AgentExpiry.isExpired(session.transcript) {
                    expiredBar(session)
                } else if let query = mentionQuery(session), let id = model.browserID {
                    let folder = query.folder(in: session.directory)
                    AgentMentionHints(
                        query: query,
                        project: session.directory,
                        directory: model.directory(folder, sessionID: id),
                        isLoading: model.isLoadingDirectory(folder, sessionID: id),
                        failure: model.browseFailure(folder, sessionID: id)
                    ) { path, isFolder in
                        drafts[session.id] = query.replacing(in: drafts[session.id] ?? "", with: path, isFolder: isFolder)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                    .transition(.scale(scale: 0.94, anchor: .bottom).combined(with: .opacity))
                } else if let items = slashItems(session) {
                    AgentSlashList(items: items) { runSlash($0, in: session) }
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                        .transition(.scale(scale: 0.94, anchor: .bottom).combined(with: .opacity))
                } else {
                    let followUps = (drafts[session.id] ?? "").isEmpty ? AgentFollowUps.suggestions(for: session.transcript) : []
                    if !followUps.isEmpty {
                        AgentFollowUpBar(suggestions: followUps) { follow(up: $0, in: session) }
                            .transition(.blurReplace)
                    }
                    optionsBar(session)
                        .transition(.blurReplace)
                }
                if !AgentExpiry.isExpired(session.transcript) {
                    AgentComposer(
                        text: draft,
                        isFocused: $composerFocused,
                        isWorking: session.transcript.state == .working,
                        canSend: AgentDraft.canSend(
                            draft: drafts[session.id] ?? "",
                            attachedCount: (attached[session.id] ?? []).filter { $0.failure == nil }.count,
                            isUploading: attaching != nil
                        ),
                        send: { send(session) },
                        attach: attachAvailable
                            ? { source in
                                switch source {
                                case .files: showsAttachPicker = true
                                case .photos: showsPhotoPicker = true
                                }
                            }
                            : nil,
                        stop: { model.interruptAgent(session.id) }
                    )
                }
            }
            // Down through the keyboard's own area too: the keyboard is translucent, and without this the transcript showed through it.
            .background(ColorPalette.backdrop.ignoresSafeArea(.all, edges: .bottom))
            .animation(Motion.settle, value: attaching == nil)
            .animation(Motion.settle, value: session.transcript.runningSubagents.count)
        }
        .photosPicker(isPresented: $showsPhotoPicker, selection: $pickedPhoto, matching: .images)
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            pickedPhoto = nil
            Task { await attachPhoto(item, session: session) }
        }
        .fileImporter(
            isPresented: $showsAttachPicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            beginAttachment(url, session: session)
        }
        .onChange(of: model.isWritingFile(sessionID: model.browserID ?? UUID())) { _, writing in
            guard !writing, var pending = attaching else { return }
            attaching = nil
            pending.failure = model.uploadFailure(sessionID: model.browserID ?? UUID())
            attached[currentID, default: []].append(pending)
        }
        .sheet(item: $openedSubagent) { selection in
            AgentSubagentSheet(sessionID: currentID, selectedCallID: selection.id)
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $answering) { approval in
            AgentApprovalSheet(approval: approval) { decision in
                model.respondToAgentApproval(approval.id, decision: decision, in: session.id)
                answering = nil
            }
            .presentationDragIndicator(.visible)
        }
    }

    private func emptyChat(_ session: RemoteAgentSession) -> some View {
        AgentEmptyChat(
            agent: TerminalAgent.all.first { $0.id == session.agentID },
            session: session,
            compact: composerFocused
        ) { text in
            stickToBottom = true
            model.sendAgentPrompt(text, to: session.id)
        }
    }

    private var ended: some View {
        VStack(spacing: 6) {
            Text("This chat has ended.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(ColorPalette.ink)
            Text("Start a new one from Mac terminals.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
