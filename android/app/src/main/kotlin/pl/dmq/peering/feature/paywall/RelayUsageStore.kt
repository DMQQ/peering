package pl.dmq.peering.feature.paywall

/** Where the day's relay use is kept between launches. */
interface RelayUsageStore {
    fun load(): DailyRelayUsage?

    fun save(usage: DailyRelayUsage)
}
