package pl.dmq.peering.ui.wiring

import pl.dmq.peering.session.ports.DiscoveredHost

/** The nearby list with [host] in it. A host seen again replaces its earlier entry, so the list holds one row per id. */
internal fun List<DiscoveredHost>.withFound(host: DiscoveredHost): List<DiscoveredHost> =
    filterNot { it.id == host.id } + host
