package pl.dmq.peering.ui.wiring

import kotlinx.coroutines.flow.StateFlow
import pl.dmq.peering.feature.agents.ComposerDraftStore
import pl.dmq.peering.feature.agents.FolderRecentsStore
import pl.dmq.peering.session.controller.SessionPhase
import pl.dmq.peering.session.ports.Clock

/** What the hub's own activity reads from the application: the live session and the stores the session screens share. */
internal class HubDependencies(
    val active: StateFlow<ActiveSession?>,
    val drafts: ComposerDraftStore,
    val folderRecents: FolderRecentsStore,
    val clock: Clock,
)

/** The hub serves one session: it closes when that session is replaced or gone, ended, or has given up. */
internal fun hubShouldClose(isOpenedSession: Boolean, phase: SessionPhase?): Boolean =
    !isOpenedSession || phase == SessionPhase.Ended || phase is SessionPhase.Failed
