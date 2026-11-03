import PeeringKit
import RemoteCore
import SwiftUI

extension AgentChatScreen {
    /// The composer is a bottom inset rather than the end of a stack, so the keyboard pushes it up instead of covering it.
    func bottomBar(_ session: RemoteAgentSession) -> some View {
        VStack(spacing: 0) {
            AgentGuardBanner(session: session, waiting: model.agentQueue(for: session.id).count)
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
            } else if !dictation.isListeningUI {
                let followUps = (drafts[session.id] ?? "").isEmpty ? AgentFollowUps.suggestions(for: session.transcript) : []
                let watch = watchAction(session)
                if !followUps.isEmpty || watch != nil {
                    AgentFollowUpBar(suggestions: followUps, choose: { follow(up: $0, in: session) }, watchOnMac: watch)
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
                    stop: { model.interruptAgent(session.id) },
                    dictation: dictation,
                    dictated: { insertDictation($0, into: session.id) }
                )
            }
        }
        // Down through the keyboard's own area too: the keyboard is translucent, and without this the transcript showed through it.
        .background(ColorPalette.backdrop.ignoresSafeArea(.all, edges: .bottom))
        .animation(Motion.settle, value: attaching == nil)
        .animation(Motion.settle, value: session.transcript.runningSubagents.count)
    }

    /// Nil hides the chip: no Mac to watch, or nothing yet worth watching.
    private func watchAction(_ session: RemoteAgentSession) -> (() -> Void)? {
        guard let watchOnMac, ChatWatch.isOffered(for: session.transcript) else { return nil }
        return { watchOnMac(session.id) }
    }
}
