import MacCastKit
import RemoteCore
import SwiftUI
import UniformTypeIdentifiers

/// One chat, as its own screen: the conversation, the ask above the composer, and the composer.
///
/// Pushed from the hub, so the way to another chat is the back button and the screen holds nothing
/// about its siblings. The transcript is the model's, and every action here is one of
/// ``SessionModel``'s forwarders; what this screen owns is what is being typed, which tool cards
/// are open, and where the eye is.
struct AgentChatScreen: View {
    /// The chat on screen. A tab changes it without pushing another screen, the same way the
    /// terminal's strip works, and for the same reason: jumping between chats is a glance.
    @State var currentID: UUID

    init(sessionID: UUID) {
        _currentID = State(initialValue: sessionID)
    }

    @Environment(SessionModel.self) var model
    @Environment(\.dismiss) var dismiss

    /// What has been typed, per chat. A draft belongs to the conversation it was written in: the
    /// tab strip makes switching one tap, and a message half-written for one agent appearing over
    /// another's transcript is a message sent to the wrong place waiting to happen.
    @State var drafts: [UUID: String] = [:]
    @State var expandedTools: Set<UUID> = []
    /// The chat a close was asked for and not yet confirmed.
    @State var pendingClose: RemoteAgentSession?
    /// The tab whose name is being typed.
    @State var renamingID: UUID?
    @State var renameText = ""
    /// The ask currently open as a sheet. The Mac's approval, not a flag: the sheet is about one
    /// ask, and answering it is what closes it.
    @State var answering: AgentApproval?
    /// The chat whose model is being typed, and what has been typed.
    @State var typingModelFor: UUID?
    @State var modelText = ""
    /// The system picker, and the file it handed over while it is on its way to the Mac.
    @State var showsAttachPicker = false
    @State var attaching: Attachment?
    @State var stickToBottom = true
    @FocusState var composerFocused: Bool

    var session: RemoteAgentSession? {
        model.agentSessions.first { $0.id == currentID }
    }

    var body: some View {
        Group {
            if let session {
                VStack(spacing: 0) {
                    tabStrip
                    content(session)
                }
            } else {
                ended
            }
        }
        .background(ColorPalette.backdrop)
        .navigationTitle(session?.title ?? String(localized: "Chat"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(ColorPalette.backdrop, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            // **What this is and where it works, in the bar.** The screen used to be titled with
            // the session's own name — "Claude Code · app" — which said the folder only when the
            // folder happened to be one word long and never said the rest of it. Two lines say
            // both properly, and the name answers "who am I talking to" at a glance.
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
                if let session, model.hostSupportsAgentPermissionModes, session.permissionModes.count > 1 {
                    AgentPermissionModeMenu(session: session)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if let session, offersModelPicker(session) {
                    modelMenu(session)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if let session {
                    Button { pendingClose = session } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(Text("Close \(session.title)"))
                }
            }
            // No keyboard bar here, and the one that was here is why: with the composer on the
            // bottom safe-area inset, an accessory row on the keyboard is counted twice — the
            // bar's height is added above a keyboard that already includes it — and the field
            // floated a row too high with a band of nothing under it. Dragging the transcript
            // puts the keyboard away instead.
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
                model.closeAgentSession(session.id)
                pendingClose = nil
                dismiss()
            }
        )
        .onAppear { model.selectedAgentSessionID = currentID }
        .onChange(of: currentID) { _, id in model.selectedAgentSessionID = id }
        // **The ask opens itself.** An approval is the one thing in a chat that stops the agent
        // until a person acts, and a card sitting quietly at the bottom of a transcript is a card
        // that gets missed. A sheet arrives over everything, and the chip above the composer is
        // what is left once it has been swiped away without an answer.
        .onChange(of: session?.transcript.pendingApprovals.first?.id, initial: true) { _, id in
            guard let id else {
                answering = nil
                return
            }
            if answering?.id != id, let approval = session?.transcript.pendingApprovals.first {
                answering = approval
            }
        }
        // A chat that is gone leaves the screen showing another one, or leaves the cover: a screen
        // with nothing in it is a dead end.
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

    // MARK: - The model

    /// What the bar calls this chat: the agent's own name rather than the Mac's title for the
    /// session, because the folder is on the line below it.
    private func agentName(_ session: RemoteAgentSession) -> String {
        TerminalAgent.all.first { $0.id == session.agentID }?.name ?? session.title
    }

    /// Whether the picker is offered at all: the Mac has said it can change a model, and this is
    /// one of the two agents known to take one. A control that would silently do nothing is worse
    /// than one that was never drawn.
    private func offersModelPicker(_ session: RemoteAgentSession) -> Bool {
        model.hostSupportsAgentModelPicker
            && (session.agentID == "claude" || session.agentID == "codex")
    }

    /// The models offered by name. Only Claude's, because they are the CLI's own documented
    /// aliases; Codex models are the account's own and are typed in through "Custom".
    private func modelSuggestions(_ agentID: String) -> [String] {
        agentID == "claude" ? ["sonnet", "opus", "haiku"] : []
    }

    private func modelMenu(_ session: RemoteAgentSession) -> some View {
        Menu {
            Button {
                model.setAgentModel(nil, in: session.id)
            } label: {
                Text("Default")
            }
            ForEach(modelSuggestions(session.agentID), id: \.self) { name in
                Button {
                    model.setAgentModel(name, in: session.id)
                } label: {
                    // Matched on the front of the name, because the CLI answers an alias with a
                    // dated full name: asking for "sonnet" is what puts "claude-sonnet-4-5-…" here.
                    if let current = session.model, current.hasPrefix(name) || current.contains(name) {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
            Divider()
            Button("Custom…") {
                modelText = session.model ?? ""
                typingModelFor = session.id
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "cpu")
                    .font(.system(size: 12, weight: .semibold))
                Text(shortModel(session))
                    .font(.system(size: 14))
                    .lineLimit(1)
            }
        }
        .accessibilityLabel(Text("Model, \(shortModel(session))"))
    }

    /// What the toolbar says. A dated full name is a paragraph in a navigation bar, so the family
    /// is what is left of it.
    private func shortModel(_ session: RemoteAgentSession) -> String {
        guard let name = session.model else { return String(localized: "Default") }
        var short = name.hasPrefix("claude-") ? String(name.dropFirst("claude-".count)) : name
        if let dash = short.lastIndex(of: "-") {
            let tail = short[short.index(after: dash)...]
            if tail.count == 8, tail.allSatisfy(\.isNumber) { short = String(short[..<dash]) }
        }
        return short
    }

    /// The open chats, as tabs, with the state each one is in.
    var tabStrip: some View {
        TabStrip(items: model.agentSessions, selection: currentID) { session, isSelected in
            chip(session, isSelected: isSelected)
        } accessory: {
            EmptyView()
        }
    }

    func chip(_ session: RemoteAgentSession, isSelected: Bool) -> some View {
        TabChip(
            isSelected: isSelected,
            onSelect: { withAnimation(Motion.tap) { currentID = session.id } },
            onClose: { pendingClose = session },
            closeLabel: String(localized: "Close \(session.title)")
        ) {
            mark(for: session.state)
        } name: {
            TabName(text: session.title, isSelected: isSelected, colour: .white)
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { beginRename(session) })
        .contextMenu {
            Button("Rename", systemImage: "character.cursor.ibeam") { beginRename(session) }
                .menuInk()
            Button("Close", systemImage: "xmark", role: .destructive) { pendingClose = session }
                .menuDanger()
        }
    }

    func beginRename(_ session: RemoteAgentSession) {
        renameText = session.title
        renamingID = session.id
    }

    /// The tab's own state mark, in the slot every strip uses.
    @ViewBuilder
    func mark(for state: AgentSessionState) -> some View {
        switch state {
        case .working:
            ProgressView()
                .controlSize(.mini)
                .tint(.secondary)
        case .awaitingApproval:
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ColorPalette.caution)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ColorPalette.danger)
        case .idle, .exited:
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    /// The conversation, with the composer riding the safe area above the keyboard.
    ///
    /// The composer is an inset at the bottom edge rather than a view at the end of a stack, which
    /// is the whole of why the keyboard pushes it up instead of drawing over it.
    @ViewBuilder
    private func content(_ session: RemoteAgentSession) -> some View {
        ZStack {
            if session.transcript.isEmpty {
                emptyChat(session)
                    .transition(.opacity)
            } else {
                AgentChatTranscript(
                    session: session,
                    expandedTools: $expandedTools,
                    stickToBottom: $stickToBottom,
                    canSend: session.transcript.state != .working,
                    resend: { text in
                        stickToBottom = true
                        model.sendAgentPrompt(text, to: session.id)
                    }
                )
                .transition(.opacity)
            }
        }
        .animation(Motion.settle, value: session.transcript.isEmpty)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                // Floating suggestions: in a chat with nothing said yet they ride above the
                // composer and go when the first message does. Suggestions parked in the middle of
                // the screen are read once and then in the way of the conversation that replaces
                // them; here they are where the hand already is, and they leave on their own.
                if session.transcript.isEmpty, session.transcript.pendingApprovals.isEmpty {
                    AgentSuggestionStrip { text in
                        drafts[session.id] = text
                        composerFocused = true
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                // What is left of an ask that was swiped away unanswered: one line, and one tap
                // back into it. An approval nobody can find again is a chat that has stopped with
                // no way of saying so.
                if let approval = session.transcript.pendingApprovals.first, answering == nil {
                    Button { answering = approval } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "hand.raised.fill")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Waiting on you")
                                .font(.system(size: 13, weight: .medium))
                            Spacer(minLength: 6)
                            Text("Review")
                                .font(.system(size: 12, weight: .semibold))
                            Image(systemName: "chevron.up")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(ColorPalette.caution)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(ColorPalette.caution.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(ColorPalette.caution.opacity(0.3))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 2)
                    .transition(.opacity)
                }
                // A file on its way, or one that did not make it: one line, and only while there
                // is something to say. What it becomes on arrival is a mention in the message,
                // which is the part both agents can act on.
                if let attaching {
                    attachmentLine(attaching, session: session)
                }
                AgentComposer(
                    text: draft,
                    isFocused: $composerFocused,
                    isWorking: session.transcript.state == .working,
                    canSend: session.transcript.state != .working
                        && !(drafts[session.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    send: { send(session) },
                    attach: attachAvailable ? { showsAttachPicker = true } : nil,
                    stop: { model.interruptAgent(session.id) }
                )
            }
            .background(ColorPalette.backdrop)
            .animation(Motion.tap, value: session.transcript.pendingApprovals.isEmpty)
            .animation(Motion.settle, value: attaching)
        }
        // Sending is the same mechanism the file browser uses: chunked writes through this
        // phone's browsing scope, into the folder this chat works in. Nothing about it needs a
        // shell, and nothing about it is new on the wire.
        .fileImporter(
            isPresented: $showsAttachPicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            beginAttachment(url, session: session)
        }
        // The Mac's answer, by the only signal there is: the write stops being in flight. A
        // failure that arrived instead is said on the line above the composer.
        .onChange(of: model.isWritingFile(sessionID: model.browserID ?? UUID())) { _, writing in
            guard !writing, let pending = attaching else { return }
            attaching = nil
            if model.uploadFailure(sessionID: model.browserID ?? UUID()) == nil {
                let mention = "@" + pending.path
                let existing = drafts[currentID] ?? ""
                drafts[currentID] = existing.isEmpty ? mention + " " : existing + " " + mention + " "
                composerFocused = true
            }
        }
        .sheet(item: $answering) { approval in
            AgentApprovalSheet(approval: approval) { decision in
                model.respondToAgentApproval(approval.id, decision: decision, in: session.id)
                answering = nil
            }
            // As tall as what is in it, rather than one fixed size for every ask: a two-line
            // permission question and a five-option choice are not the same sheet, and a medium
            // detent gave the first one a screenful of nothing under it.
            .presentationSizing(.fitted)
            .presentationDragIndicator(.visible)
        }
    }

    /// A chat with nothing said in it yet, which was a black screen with a field on it.
    ///
    /// What the user needs here is what this is and what to ask it, so the screen names the agent,
    /// says where it is working, and offers three things a coding agent can be asked. A tap puts
    /// the question in the composer rather than sending it: the first prompt deserves to be read
    /// before it goes.
    private func emptyChat(_ session: RemoteAgentSession) -> some View {
        let agent = TerminalAgent.all.first { $0.id == session.agentID }
        return VStack(spacing: 12) {
            Spacer(minLength: 20)
            IconTile(symbol: agent?.symbol ?? "sparkles", size: 56)
            VStack(spacing: 5) {
                Text(verbatim: agent?.name ?? session.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ColorPalette.ink)
                Text(session.directory)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 24)
            }
            if session.state == .exited || session.state == .failed {
                Text("This chat has ended. Its conversation is above; start a new chat to keep going.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Runs on your Mac, not here. It keeps working when you disconnect.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
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

    /// Whether an attachment can be sent at all: the file lane exists, and this Mac announced it.
    /// A clip that opens a picker and then does nothing is worse than no clip.
    private var attachAvailable: Bool {
        model.browserID != nil && model.hostSupportsFileBrowser
    }

    private func beginAttachment(_ url: URL, session: RemoteAgentSession) {
        guard let id = model.browserID else { return }
        let name = url.lastPathComponent
        let folder = session.directory
        let path = folder.hasSuffix("/") ? folder + name : folder + "/" + name
        attaching = Attachment(name: name, path: path)
        model.uploadFile(url, toFolder: folder, sessionID: id)
    }

    /// What the line above the composer says while a file is going, or why it did not.
    @ViewBuilder
    private func attachmentLine(_ attachment: Attachment, session: RemoteAgentSession) -> some View {
        let id = model.browserID ?? UUID()
        let failure = model.uploadFailure(sessionID: id)
        HStack(spacing: 7) {
            if failure == nil {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.secondary)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ColorPalette.danger)
            }
            Text(failure ?? String(localized: "Sending \(attachment.name) to your Mac…"))
                .font(.system(size: 12))
                .foregroundStyle(failure == nil ? .secondary : ColorPalette.danger)
                .lineLimit(2)
            Spacer(minLength: 6)
            Button {
                attaching = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .transition(.opacity)
    }

    /// The composer's own text, which is this chat's draft and no other's.
    private var draft: Binding<String> {
        Binding(
            get: { drafts[currentID] ?? "" },
            set: { drafts[currentID] = $0 }
        )
    }

    private func send(_ session: RemoteAgentSession) {
        let text = drafts[session.id] ?? ""
        drafts[session.id] = ""
        stickToBottom = true
        model.sendAgentPrompt(text, to: session.id)
    }
}

/// A file on its way into the chat's folder.
struct Attachment: Equatable {
    /// What it is called on the phone, for the line that says it is going.
    let name: String
    /// Where it lands on the Mac, which is what goes into the message when it arrives.
    let path: String
}

/// The three things a chat screen offers before anything has been asked.
private enum AgentSuggestions {
    static let all: [String] = [
        String(localized: "What does this project do?"),
        String(localized: "Fix the failing tests"),
        String(localized: "Review the latest changes"),
    ]
}

/// The suggestions, as chips that float above the composer.
///
/// Each is a glass capsule, the same material the session chrome's controls are made of, so they
/// read as something laid over the chat rather than as part of it. A tap fills the composer rather
/// than sending: the first prompt in a chat deserves to be read before it goes.
private struct AgentSuggestionStrip: View {
    let pick: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(AgentSuggestions.all, id: \.self) { text in
                    Button { pick(text) } label: {
                        Text(text)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(ColorPalette.ink)
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .glassSurface(in: Capsule(), interactive: true)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

// MARK: - The transcript

/// The conversation, drawn from the session's own transcript.
private struct AgentChatTranscript: View {
    let session: RemoteAgentSession
    @Binding var expandedTools: Set<UUID>
    @Binding var stickToBottom: Bool
    /// Whether a question can be asked again right now: a turn already running cannot take one
    /// for Codex, so the row offers nothing rather than a tap that goes nowhere.
    let canSend: Bool
    let resend: (String) -> Void

    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if session.transcript.truncatedAtFront {
                        Text("The start of this conversation is no longer on the Mac.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.45))
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    ForEach(session.transcript.items) { item in
                        AgentTranscriptRow(
                            item: item,
                            expandedTools: $expandedTools,
                            canSend: canSend,
                            resend: resend
                        )
                    }
                    if let failure = session.failure {
                        Text(failure)
                            .font(.footnote)
                            .foregroundStyle(ColorPalette.danger)
                    }
                    Color.clear.frame(height: 1).id("chat-end")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            // Dragging the conversation puts the keyboard away, the same way the terminal's log
            // does: the composer is pinned to the bottom, and reading above it is the other thing
            // a thumb does here.
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height
                    >= geometry.contentSize.height - 40
            } action: { _, atBottom in
                // The same manual stick-to-bottom the terminal uses: a default scroll anchor
                // fights a finger that has scrolled up to read.
                stickToBottom = atBottom
            }
            .onChange(of: session.transcript.items.count) { _, _ in
                guard stickToBottom else { return }
                withAnimation(Motion.settle) { reader.scrollTo("chat-end", anchor: .bottom) }
            }
            // A tab switching chats arrives at the end of the new one, wherever the last was left:
            // the bottom of a conversation is the part anybody wants first.
            .onChange(of: session.id) { _, _ in
                stickToBottom = true
                reader.scrollTo("chat-end", anchor: .bottom)
            }
        }
    }
}

/// One row of the conversation.
private struct AgentTranscriptRow: View {
    let item: AgentTranscriptItem
    @Binding var expandedTools: Set<UUID>
    let canSend: Bool
    let resend: (String) -> Void

    var body: some View {
        switch item {
        case .user(let id, let text):
            HStack {
                Spacer(minLength: 40)
                AgentPlainText(text: text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(LinearGradient(
                                colors: [.white.opacity(0.09), .white.opacity(0.045)],
                                startPoint: .top, endPoint: .bottom
                            ))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.07))
                    }
                    // What a question one has already asked is worth: reading it back, copying it,
                    // and asking it again — the last of which is what a failed or stopped turn
                    // leaves a person wanting.
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
                            .menuInk()
                        if canSend {
                            Button("Ask again", systemImage: "arrow.clockwise") { resend(text) }
                                .menuInk()
                        }
                    }
            }
            .id(id)

        case .reply(let id, let text):
            AgentMarkdownText(text: text)
                .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
                        .menuInk()
                }
                .id(id)

        case .tool(let id, let tool):
            AgentToolCard(tool: tool, isExpanded: expandedTools.contains(id)) {
                withAnimation(Motion.settle) {
                    if expandedTools.contains(id) { expandedTools.remove(id) } else { expandedTools.insert(id) }
                }
            }
            .contextMenu {
                if let output = tool.output, !output.isEmpty {
                    Button("Copy output", systemImage: "doc.on.doc") { UIPasteboard.general.string = output }
                        .menuInk()
                }
                if let detail = tool.call.detail, !detail.isEmpty {
                    Button("Copy \(tool.call.title)", systemImage: "terminal") { UIPasteboard.general.string = detail }
                        .menuInk()
                }
                Button(
                    expandedTools.contains(id) ? "Hide details" : "Show details",
                    systemImage: expandedTools.contains(id) ? "chevron.up" : "chevron.down"
                ) {
                    withAnimation(Motion.settle) {
                        if expandedTools.contains(id) { expandedTools.remove(id) } else { expandedTools.insert(id) }
                    }
                }
                .menuInk()
            }
            .id(id)

        case .notice(_, let text):
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.caption)
                Text(text)
                    .font(.footnote)
            }
            .foregroundStyle(.white.opacity(0.5))

        case .failure(_, let text):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption)
                Text(text)
                    .font(.footnote)
            }
            .foregroundStyle(ColorPalette.danger)

        case .summary(_, let summary):
            AgentTurnSummaryPill(summary: summary)
        }
    }
}

/// The reply text, with the block structure the markdown splitter found.
private struct AgentMarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(AgentMarkdown.split(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let paragraph):
                    inline(paragraph)
                        .font(.system(size: 15.5))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                case .heading(let level, let heading):
                    inline(heading)
                        .font(.system(size: level <= 2 ? 17 : 15.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.top, 2)
                        .textSelection(.enabled)
                case .code(let code):
                    AgentMonospaceBlock(text: code)
                case .bullets(let bullets):
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(bullets.enumerated()), id: \.offset) { _, bullet in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text("•")
                                    .font(.system(size: 15.5))
                                    .foregroundStyle(.white.opacity(0.5))
                                inline(bullet)
                                    .font(.system(size: 15.5))
                                    .foregroundStyle(.white.opacity(0.95))
                                    .lineSpacing(3)
                            }
                        }
                    }
                    .padding(.leading, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Inline markdown (`code`, **bold**) when it parses, the raw text when it does not: a
    /// half-typed `**` mid-stream must not make the line vanish.
    private func inline(_ string: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(string)
    }
}

/// User text and tool output: drawn as typed, never re-flowed as markdown.
private struct AgentPlainText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 15.5))
            .foregroundStyle(.white.opacity(0.95))
            .lineSpacing(3)
            .textSelection(.enabled)
    }
}

/// A monospaced block that scrolls sideways rather than wrapping: a command that wraps is a
/// command with invented line breaks in it.
private struct AgentMonospaceBlock: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(10)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.05))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.07))
        }
    }
}

/// One tool call, drawn as a card: what ran, where, and what came back.
private struct AgentToolCard: View {
    let tool: AgentToolItem
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 28, height: 28)
                        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.call.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                        if let detail = tool.call.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.caption.monospaced())
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(isExpanded ? nil : 2)
                        }
                    }
                    Spacer(minLength: 6)
                    statusGlyph
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                if let diff = tool.call.diff, !diff.isEmpty {
                    AgentDiffBlock(diff: diff)
                }
                if let output = tool.output, !output.isEmpty {
                    AgentMonospaceBlock(text: tool.truncated ? output + "\n… (truncated)" : output)
                }
                if tool.call.diff == nil, tool.output == nil, tool.state == .running {
                    Text("Running…")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .padding(11)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.16), .white.opacity(0.05)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        }
    }

    private var symbol: String {
        switch tool.state {
        case .awaitingApproval: return "hand.raised"
        case .denied: return "nosign"
        case .failed: return "xmark"
        case .ok: return "checkmark"
        case .running: return "ellipsis"
        }
    }

    private var tint: Color {
        switch tool.state {
        case .awaitingApproval, .denied: return ColorPalette.caution
        case .failed: return ColorPalette.danger
        case .ok, .running: return .white.opacity(0.85)
        }
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch tool.state {
        case .running:
            ProgressView()
                .controlSize(.mini)
                .tint(.white.opacity(0.6))
        case .awaitingApproval:
            Text("Needs you")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(ColorPalette.caution)
        case .denied:
            Text("Denied")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(ColorPalette.caution)
        case .failed:
            Text("Failed")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(ColorPalette.danger)
        case .ok:
            Image(systemName: "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.45))
        }
    }
}

/// A diff, drawn as a card: the file it is about, how much moved, and then the lines.
///
/// No red and green, and the prefix is what carries the meaning — the same rule the palette keeps
/// everywhere: colour here would be a second, louder copy of a `+`. What a change *looks* like is
/// a band of brighter text on a faint lift for additions, and dimmed text for removals, which
/// survives being read on a phone in daylight and at night.
private struct AgentDiffBlock: View {
    let diff: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    row(line)
                }
            }
            .padding(.vertical, 5)
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.05))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08))
        }
    }

    /// The file, and the two counts. The `---`/`+++` pair the CLI writes is a file header rather
    /// than a change, so it is drawn as one and not as two lines of the diff.
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            Text(path ?? String(localized: "Changes"))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if added > 0 {
                Text("+\(added)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
            }
            if removed > 0 {
                Text("-\(removed)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    /// One line, wrapped rather than scrolled sideways: a diff is the one block where the whole
    /// line has to be readable, and a horizontal scroller inside a chat is a line half of which is
    /// off screen at the moment it matters.
    private func row(_ line: String) -> some View {
        let kind = kind(of: line)
        return HStack(alignment: .top, spacing: 8) {
            Text(marker(kind))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(kind == .context ? .white.opacity(0.3) : .white.opacity(0.75))
                .frame(width: 9, alignment: .leading)
            Text(String(line.dropFirst(kind == .context ? 0 : 1)))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(textColour(kind))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 1.5)
        .background(kind == .added ? Color.white.opacity(0.06) : .clear)
    }

    private enum Kind { case added, removed, context }

    private func kind(of line: String) -> Kind {
        if line.hasPrefix("+++ ") { return .context }
        if line.hasPrefix("+") { return .added }
        if line.hasPrefix("-") { return .removed }
        return .context
    }

    private func marker(_ kind: Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "-"
        case .context: return " "
        }
    }

    private func textColour(_ kind: Kind) -> Color {
        switch kind {
        case .added: return .white.opacity(0.95)
        case .removed: return .white.opacity(0.45)
        case .context: return .white.opacity(0.7)
        }
    }

    /// Everything but the file header.
    private var lines: [String] {
        diff.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.hasPrefix("--- ") && !$0.hasPrefix("+++ ") }
    }

    private var path: String? {
        diff.split(separator: "\n")
            .first { $0.hasPrefix("+++ ") }
            .map { String($0.dropFirst(4)) }
    }

    private var added: Int { lines.filter { $0.hasPrefix("+") }.count }
    private var removed: Int { lines.filter { $0.hasPrefix("-") }.count }
}

/// What one finished turn cost, in the readings style the app uses for numbers.
private struct AgentTurnSummaryPill: View {
    let summary: AgentTurnSummary

    var body: some View {
        HStack(spacing: 6) {
            if summary.stopped {
                Text("Stopped")
            } else if !summary.ok {
                Text("Failed")
                    .foregroundStyle(ColorPalette.danger)
            }
            if let cost = summary.costUSD {
                Text(cost.formatted(.currency(code: "USD").precision(.fractionLength(2...4))))
            }
            if let input = summary.inputTokens, let output = summary.outputTokens {
                Text("\(input) in / \(output) out")
            }
            if let duration = summary.duration {
                Text(duration < 60
                    ? String(format: "%.1fs", duration)
                    : "\(Int(duration) / 60)m \(Int(duration) % 60)s")
            }
        }
        .font(.caption2.monospaced())
        .foregroundStyle(.white.opacity(0.45))
        .padding(.top, 2)
    }
}

// MARK: - Approval, composer

/// The ask, as a sheet over the chat: what would run, and the ways to answer it.
///
/// Two shapes behind one design. A permission ask shows what would run and two answers side by
/// side; a question ask shows the question and one row per choice, and a row *is* the answer.
private struct AgentApprovalSheet: View {
    let approval: AgentApproval
    let answer: (AgentApprovalDecision) -> Void

    private var call: AgentToolCall { approval.call }

    private var options: [AgentToolOption] { call.options ?? [] }

    var body: some View {
        // A plain stack rather than a scroller: the sheet is sized to its content, and a scroll
        // view's idea of its ideal height is "as much as you will give me", which is a sheet that
        // fits itself to the screen and defeats the point.
        VStack(alignment: .leading, spacing: 16) {
            header
            if let detail = approval.reason ?? call.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineSpacing(2)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if options.isEmpty {
                HStack(spacing: 10) {
                    side("Deny", filled: false) { answer(.deny) }
                    side("Allow", filled: true) { answer(.allow) }
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(options.enumerated()), id: \.element.label) { _, option in
                        optionRow(option)
                    }
                }
            }
        }
        .padding(20)
        .background(ColorPalette.backdrop)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: options.isEmpty ? "hand.raised.fill" : "questionmark.bubble.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ColorPalette.caution)
                .frame(width: 30, height: 30)
                .background(ColorPalette.caution.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: call.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(options.isEmpty ? "Wants to run on your Mac" : "Asks a question")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
        }
    }

    /// One of the two answers to a permission ask, drawn as half the row so neither is the button
    /// you have to find: they are the only two things this sheet does.
    private func side(_ label: String, filled: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(label)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(filled ? ColorPalette.onInk : .white)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background {
                    if filled {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ColorPalette.ink)
                    } else {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.22))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func optionRow(_ option: AgentToolOption) -> some View {
        Button {
            answer(.choose(option.label))
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                    if let detail = option.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.22))
            )
        }
        .buttonStyle(.plain)
    }
}

/// The prompt row: multiline growth, a send that becomes a stop while a turn runs.
private struct AgentComposer: View {
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool
    let isWorking: Bool
    let canSend: Bool
    let send: () -> Void
    /// Sends a file into the chat's folder, and puts its path in the message when it lands.
    /// Absent where the Mac cannot do it, which draws no clip rather than a clip that does nothing.
    var attach: (() -> Void)?
    let stop: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if let attach {
                Button(action: attach) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(isWorking)
                .opacity(isWorking ? 0.4 : 1)
                .accessibilityLabel("Attach a file")
            }

            TextField("Message", text: $text, axis: .vertical)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .lineLimit(1...6)
                .focused($isFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                // Readable at a glance, which the first cut of this was not: at six per cent over a
                // near-black page the field was a rumour of a rectangle rather than the thing the
                // whole screen is for.
                .background {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.white.opacity(0.1))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.16))
                }
                .disabled(isWorking)

            Button {
                isWorking ? stop() : send()
            } label: {
                Image(systemName: isWorking ? "stop.fill" : "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(isWorking ? .white : ColorPalette.onInk)
                    .frame(width: 34, height: 34)
                    .background(
                        Circle().fill(isWorking
                            ? AnyShapeStyle(.white.opacity(0.14))
                            : AnyShapeStyle(canSend ? ColorPalette.ink : .white.opacity(0.25)))
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!isWorking && !canSend)
            .accessibilityLabel(isWorking ? "Stop" : "Send")
        }
        // The button changing its job — send becoming stop — is the one place in this row where a
        // shape changes rather than a shade, so it is the one place an animation is owed.
        .animation(Motion.tap, value: isWorking)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        // A band rather than a floating row: the seam is what says the conversation ends here and
        // the controls begin, and the slight lift keeps the field from sharing the page's black.
        .background(Color.white.opacity(0.02).overlay(ColorPalette.backdrop))
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
        }
    }
}
