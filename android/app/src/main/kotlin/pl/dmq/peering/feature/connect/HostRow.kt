package pl.dmq.peering.feature.connect

/** Whether a sleeping computer can be woken from here. A computer seen up needs no waking, and one with no hardware address on file cannot be woken. */
enum class WakeState { Available, NoAddress, Awake }

data class HostRow(
    val id: String,
    val name: String?,
    val status: HostStatus,
    val route: HostRoute = HostRoute.None,
    val wake: WakeState = WakeState.NoAddress,
)
