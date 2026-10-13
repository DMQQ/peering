package pl.dmq.peering.feature.remote

import pl.dmq.peering.feature.paywall.RelayAllowance

/** The whole minutes of relay time left today, or null when the plan has no limit. */
fun relayMinutesLeft(allowance: RelayAllowance): Int? =
    if (allowance.paid) null else (allowance.remainingSeconds / SECONDS_PER_MINUTE).toInt()

private const val SECONDS_PER_MINUTE = 60L
