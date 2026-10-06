import MacCastKit
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
    @State var typingModelFor: UUID?
    @State var modelText = ""
    @State var showsAttachPicker = false
    @State var attaching: Attachment?
    @State var stickToBottom = true
    @FocusState var composerFocused: Bool
    @State private var showsUsage = false

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
        .sheet(isPresented: $showsUsage) {
            AgentUsageSheet(sessionID: currentID)
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
                if session != nil, model.hostSupportsAgentUsage {
                    Button { showsUsage = true } label: {
                        Image(systemName: "gauge.with.dots.needle.33percent")
                    }
                    .accessibilityLabel(Text("Usage"))
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
                model.closeAgentSession(session.id)
                pendingClose = nil
                dismiss()
            }
        )
        .onAppear { model.selectedAgentSessionID = currentID }
        .onChange(of: currentID) { _, id in model.selectedAgentSessionID = id }
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

    // MARK: - The model

    private func agentName(_ session: RemoteAgentSession) -> String {
        TerminalAgent.all.first { $0.id == session.agentID }?.name ?? session.title
    }

    private func offersModelPicker(_ session: RemoteAgentSession) -> Bool {
        model.hostSupportsAgentModelPicker
            && (session.agentID == "claude" || session.agentID == "codex")
    }

    /// Only Claude's models are listed (the CLI's documented aliases); Codex models are typed in through Custom.
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
                    // Matched on the front of the name: the CLI answers an alias with a dated full name.
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

    private func shortModel(_ session: RemoteAgentSession) -> String {
        guard let name = session.model else { return String(localized: "Default") }
        var short = name.hasPrefix("claude-") ? String(name.dropFirst("claude-".count)) : name
        if let dash = short.lastIndex(of: "-") {
            let tail = short[short.index(after: dash)...]
            if tail.count == 8, tail.allSatisfy(\.isNumber) { short = String(short[..<dash]) }
        }
        return short
    }

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

    /// The composer is a bottom inset rather than the end of a stack, so the keyboard pushes it up instead of covering it.
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
                if session.transcript.isEmpty, session.transcript.pendingApprovals.isEmpty {
                    AgentSuggestionStrip { text in
                        drafts[session.id] = text
                        composerFocused = true
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
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
        .fileImporter(
            isPresented: $showsAttachPicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            beginAttachment(url, session: session)
        }
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
            // Sized to content: a medium detent left a screenful of nothing under a short ask.
            .presentationSizing(.fitted)
            .presentationDragIndicator(.visible)
        }
    }

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

struct Attachment: Equatable {
    let name: String
    let path: String
}

private enum AgentSuggestions {
    static let all: [String] = [
        String(localized: "What does this project do?"),
        String(localized: "Fix the failing tests"),
        String(localized: "Review the latest changes"),
    ]
}

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

private struct AgentChatTranscript: View {
    let session: RemoteAgentSession
    @Binding var expandedTools: Set<UUID>
    @Binding var stickToBottom: Bool
    /// A running Codex turn cannot take another question.
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
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height
                    >= geometry.contentSize.height - 40
            } action: { _, atBottom in
                // Manual stick-to-bottom: a default scroll anchor fights a finger that has scrolled up.
                stickToBottom = atBottom
            }
            .onChange(of: session.transcript.items.count) { _, _ in
                guard stickToBottom else { return }
                withAnimation(Motion.settle) { reader.scrollTo("chat-end", anchor: .bottom) }
            }
            .onChange(of: session.id) { _, _ in
                stickToBottom = true
                reader.scrollTo("chat-end", anchor: .bottom)
            }
        }
    }
}

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

    /// Raw text when markdown does not parse: a half-typed `**` mid-stream must not make the line vanish.
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

/// No red and green: the +/- prefix carries the meaning, as everywhere in the palette.
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

    /// The file header pair the CLI writes (old and new path) is not two diff lines.
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

private struct AgentApprovalSheet: View {
    let approval: AgentApproval
    let answer: (AgentApprovalDecision) -> Void

    private var call: AgentToolCall { approval.call }

    private var options: [AgentToolOption] { call.options ?? [] }

    var body: some View {
        // A plain stack, not a scroller: a scroll view's ideal height is as much as it is given, which defeats a content-sized sheet.
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

private struct AgentComposer: View {
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool
    let isWorking: Bool
    let canSend: Bool
    let send: () -> Void
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
        .animation(Motion.tap, value: isWorking)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color.white.opacity(0.02).overlay(ColorPalette.backdrop))
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
        }
    }
}
