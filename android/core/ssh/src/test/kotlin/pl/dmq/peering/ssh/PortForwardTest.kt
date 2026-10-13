package pl.dmq.peering.ssh

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.ssh.model.SshForwardError
import pl.dmq.peering.ssh.model.SshForwardReading
import pl.dmq.peering.ssh.model.SshPortForward

class PortForwardTest {
    private fun read(
        local: String = "8080",
        host: String = "db.internal",
        remote: String = "5432",
        existing: List<SshPortForward> = emptyList(),
        editing: String? = null,
    ) = SshPortForward.reading("  db ", local, host, remote, existing, editing) { "new" }

    private fun error(reading: SshForwardReading) = (reading as SshForwardReading.Invalid).error

    @Test
    fun validFieldsMakeATrimmedEnabledForward() {
        val forward = (read() as SshForwardReading.Valid).forward
        assertEquals(SshPortForward("new", "db", 8080, "db.internal", 5432, true), forward)
        assertEquals("localhost:8080 to db.internal:5432", forward.detail)
    }

    @Test
    fun aNameIsOptionalAndTheDisplayFallsBackToTheAddresses() {
        assertEquals("8080 to h:1", SshPortForward("a", "", 8080, "h", 1).displayName)
    }

    @Test
    fun portsMustBeNumbersWithinRange() {
        assertEquals(SshForwardError.LOCAL_PORT_NOT_A_NUMBER, error(read(local = "")))
        assertEquals(SshForwardError.LOCAL_PORT_NOT_A_NUMBER, error(read(local = "80a")))
        assertEquals(SshForwardError.LOCAL_PORT_OUT_OF_RANGE, error(read(local = "0")))
        assertEquals(SshForwardError.LOCAL_PORT_OUT_OF_RANGE, error(read(local = "65536")))
        assertEquals(SshForwardError.REMOTE_PORT_NOT_A_NUMBER, error(read(remote = "x")))
        assertEquals(SshForwardError.REMOTE_PORT_OUT_OF_RANGE, error(read(remote = "70000")))
    }

    @Test
    fun theFarEndMustLookLikeAHostname() {
        assertEquals(SshForwardError.REMOTE_HOST_EMPTY, error(read(host = "  ")))
        assertEquals(SshForwardError.REMOTE_HOST_NOT_A_HOSTNAME, error(read(host = "ssh -L 1:2:3 box")))
        assertTrue(read(host = "::1") is SshForwardReading.Valid)
    }

    @Test
    fun twoForwardsCannotListenOnTheSamePortButEditingOneMayKeepItsOwn() {
        val existing = listOf(SshPortForward("a", "", 8080, "h", 1, isEnabled = false))
        val clash = read(existing = existing) as SshForwardReading.Invalid
        assertEquals(SshForwardError.LOCAL_PORT_ALREADY_USED, clash.error)
        assertEquals(8080, clash.port)
        val edited = (read(existing = existing, editing = "a") as SshForwardReading.Valid).forward
        assertEquals("a", edited.id)
        assertEquals(false, edited.isEnabled)
    }
}
