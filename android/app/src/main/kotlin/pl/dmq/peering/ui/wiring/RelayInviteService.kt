package pl.dmq.peering.ui.wiring

import pl.dmq.peering.feature.settings.InviteService
import pl.dmq.peering.session.relay.ReferralClient
import pl.dmq.peering.wire.RelayReferral

internal class RelayInviteService(private val client: ReferralClient) : InviteService {
    override suspend fun status(): RelayReferral = client.status()

    override suspend fun redeem(typed: String): RelayReferral = client.redeem(typed)
}
