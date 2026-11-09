package pl.dmq.peering.wire

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.decodeFromJsonElement

/**
 * A prompt the Mac sends an agent on a schedule, in a chat of its own, while the phone is away. [id] is an uppercase UUID
 * string and [agentID] a catalogue id the Mac listed. [directory] is an absolute path on the Mac. [stopAfterMinutes] absent
 * lets a run finish. [notifiesWhenDone] absent means yes, which is what a routine saved before the field existed did not say.
 * [lastRun] and [nextRunAt] (seconds since 2001-01-01) are kept by the Mac: what the phone sends is ignored.
 *
 * The booleans have no defaults on purpose: the encoder leaves defaults out, and the Mac needs every key it requires.
 */
@Serializable
data class AgentRoutine(
    val id: String,
    val name: String,
    val agentID: String,
    val directory: String,
    val prompt: String,
    val schedule: AgentRoutineSchedule,
    val permissionMode: AgentPermissionMode,
    val isEnabled: Boolean,
    val stopAfterMinutes: Int? = null,
    val notifiesWhenDone: Boolean? = null,
    val lastRun: AgentRoutineRun? = null,
    val nextRunAt: Double? = null,
) {
    val notifies: Boolean get() = notifiesWhenDone ?: true
}

/** When a routine runs. Weekdays are numbered as Swift's `Calendar` numbers them: 1 is Sunday, 7 is Saturday. */
@Serializable(with = AgentRoutineScheduleSerializer::class)
sealed class AgentRoutineSchedule {
    @Serializable
    data class Every(val minutes: Int) : AgentRoutineSchedule()

    @Serializable
    data class Daily(val hour: Int, val minute: Int, val weekdays: List<Int>) : AgentRoutineSchedule()
}

internal object AgentRoutineScheduleSerializer : SwiftCaseSerializer<AgentRoutineSchedule>() {
    private val cases: List<UnionCase<AgentRoutineSchedule>> = listOf(
        unionCase<AgentRoutineSchedule, AgentRoutineSchedule.Every>("every"),
        unionCase<AgentRoutineSchedule, AgentRoutineSchedule.Daily>("daily"),
    )

    override fun encodeCase(value: AgentRoutineSchedule): JsonObject = encodeUnion(cases, value)

    override fun decodeCase(json: JsonObject): AgentRoutineSchedule = decodeUnion(cases, json)
}

@Serializable
enum class AgentRoutineOutcome {
    @SerialName("running")
    RUNNING,

    @SerialName("succeeded")
    SUCCEEDED,

    @SerialName("failed")
    FAILED,

    /** Ended by the routine's own time limit. */
    @SerialName("stopped")
    STOPPED,

    /** Never started; [AgentRoutineRun.detail] says why. */
    @SerialName("skipped")
    SKIPPED,
}

/** One run of a routine, as the Mac last recorded it. [startedAt] is seconds since 2001-01-01; [sessionID] is absent for a skipped run. */
@Serializable
data class AgentRoutineRun(
    val startedAt: Double,
    val outcome: AgentRoutineOutcome,
    val detail: String? = null,
    val sessionID: String? = null,
)

/** The listing's entries; one the phone cannot read is dropped rather than failing the rest. */
fun AgentEvent.Routines.decoded(): List<AgentRoutine> = routines.mapNotNull { element: JsonElement ->
    runCatching { WireJson.decodeFromJsonElement<AgentRoutine>(element) }.getOrNull()
}
