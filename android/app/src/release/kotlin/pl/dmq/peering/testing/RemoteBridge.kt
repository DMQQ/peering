package pl.dmq.peering.testing

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.pager.PagerState
import androidx.compose.runtime.Composable
import pl.dmq.peering.feature.remote.ClipboardPort
import pl.dmq.peering.feature.remote.RemoteActions
import pl.dmq.peering.feature.remote.SessionScreenState
import pl.dmq.peering.feature.remote.StatusPillPresenter

@Composable
internal fun RemoteBridge(screen: SessionScreenState, pill: StatusPillPresenter, actions: RemoteActions, clipboard: ClipboardPort) = Unit

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun DockBridge(state: PagerState) = Unit
