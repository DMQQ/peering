package pl.dmq.peering.platform.discovery

import java.net.Inet4Address
import java.net.InetAddress

/**
 * Which of a resolved host's addresses to dial. Android 14+ resolves every advertised address and `NsdServiceInfo.host`
 * is just the first, often an IPv6 link-local one that cannot be dialled without its interface; that dial times out
 * after the full connect timeout instead of failing fast.
 */
internal object AddressChoice {
    fun best(addresses: List<InetAddress>): InetAddress? =
        addresses.filterNot { it.isLinkLocalAddress || it.isLoopbackAddress || it.isAnyLocalAddress }
            .minByOrNull { if (it is Inet4Address) 0 else 1 }
            ?: addresses.firstOrNull()
}
