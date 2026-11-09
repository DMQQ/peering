package pl.dmq.peering.session.agent

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import pl.dmq.peering.wire.AgentEvent
import pl.dmq.peering.wire.AgentPermissionMode
import pl.dmq.peering.wire.AgentRequest
import pl.dmq.peering.wire.AgentRoutine
import pl.dmq.peering.wire.AgentRoutineSchedule
import pl.dmq.peering.wire.WireJson

class AgentChatRoutinesTest {
    private val sent = mutableListOf<AgentRequest>()
    private val chat = AgentChat { sent += it }
    private val id = "0A1B2C3D-0000-4000-8000-00000000000F"
    private val routine = AgentRoutine(id, "N", "claude", "/w", "p", AgentRoutineSchedule.Every(60), AgentPermissionMode.PLAN, true)

    @Test
    fun routineRequestsGoOutAsTheMacExpectsThem() {
        chat.listRoutines()
        chat.saveRoutine(routine)
        chat.runRoutineNow(id)
        chat.deleteRoutine(id)
        assertEquals(
            listOf(AgentRequest.ListRoutines, AgentRequest.SaveRoutine(routine), AgentRequest.RunRoutineNow(id), AgentRequest.DeleteRoutine(id)),
            sent,
        )
    }

    @Test
    fun theRoutineListIsUnknownUntilTheMacAnswers() {
        assertNull(chat.routines.value)
        chat.onEvent(AgentEvent.Routines(listOf(WireJson.parseToJsonElement(WireJson.encodeToString(AgentRoutine.serializer(), routine)))))
        assertEquals(listOf(routine), chat.routines.value)
    }

    @Test
    fun aFailureWithNoChatAfterARoutineRequestIsTheRoutinesFailureNotTheListsOne() {
        chat.saveRoutine(routine)
        chat.onEvent(AgentEvent.Failed(null, "The folder is gone"))
        assertEquals("The folder is gone", chat.routineFailure.value)
        assertNull(chat.state.value.failure)
        chat.listRoutines()
        assertNull(chat.routineFailure.value)
    }

    @Test
    fun aFailureWhenNoRoutineRequestIsOutstandingStaysTheChatListsFailure() {
        chat.onEvent(AgentEvent.Failed(null, "No Mac answered"))
        assertNull(chat.routineFailure.value)
        assertEquals("No Mac answered", chat.state.value.failure)
    }
}
