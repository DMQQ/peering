package pl.dmq.peering.ui.wiring

import pl.dmq.peering.feature.settings.IdentityReset

/**
 * The reset is not offered yet (AND-142 decides it, since the free allowance is keyed to this identity). Asking for one
 * reports that nothing was stored, so the settings screen says so instead of pretending.
 */
internal object IdentityResetNotOffered : IdentityReset {
    override fun reset(): Boolean = false
}
