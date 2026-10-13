package pl.dmq.peering.ssh

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import pl.dmq.peering.session.ports.KeyValueStore
import pl.dmq.peering.ssh.model.SshHost
import pl.dmq.peering.ssh.model.SshHostForm
import pl.dmq.peering.ssh.model.SshHostFormError
import pl.dmq.peering.ssh.model.SshHostFormReading
import pl.dmq.peering.ssh.model.SshHostLock
import pl.dmq.peering.ssh.model.SshPortForward
import pl.dmq.peering.ssh.store.PrefixedKeyValueStore

class HostFormTest {
    private fun read(form: SshHostForm, existing: SshHost? = null) = form.reading(existing, { "new" }, { 5 })

    private fun errors(form: SshHostForm) = (read(form) as SshHostFormReading.Invalid).errors

    @Test
    fun aCompleteFormMakesATrimmedHostWithTheNewIdAndTime() {
        val form = SshHostForm(" Box ", " box.example.com ", " 2222 ", " root ", SshHostLock.BIOMETRICS)
        val host = (read(form) as SshHostFormReading.Valid).host
        assertEquals(SshHost("new", "Box", "box.example.com", 2222, "root", createdAt = 5, lock = SshHostLock.BIOMETRICS), host)
    }

    @Test
    fun theNameIsOptional() {
        val host = (read(SshHostForm(hostname = "h", username = "u")) as SshHostFormReading.Valid).host
        assertEquals("h", host.displayName)
    }

    @Test
    fun everyProblemIsReportedAtOnce() {
        assertEquals(
            setOf(SshHostFormError.HOSTNAME_EMPTY, SshHostFormError.PORT_INVALID, SshHostFormError.USERNAME_EMPTY),
            errors(SshHostForm(port = "0")),
        )
        assertEquals(setOf(SshHostFormError.PORT_INVALID), errors(SshHostForm(hostname = "h", username = "u", port = "65536")))
        assertEquals(setOf(SshHostFormError.PORT_INVALID), errors(SshHostForm(hostname = "h", username = "u", port = "x")))
    }

    @Test
    fun aHostnameWithAUserOrASlashInItIsNotAHostname() {
        assertEquals(setOf(SshHostFormError.HOSTNAME_INVALID), errors(SshHostForm(hostname = "root@box", username = "u")))
        assertEquals(setOf(SshHostFormError.HOSTNAME_INVALID), errors(SshHostForm(hostname = "ssh://box", username = "u")))
        assertEquals(setOf(SshHostFormError.HOSTNAME_INVALID), errors(SshHostForm(hostname = "my box", username = "u")))
    }

    @Test
    fun editingKeepsTheIdForwardsAndLastConnection() {
        val forward = SshPortForward("f", localPort = 1, remoteHost = "h", remotePort = 2)
        val existing = SshHost("keep", "Old", "old", 22, "u", createdAt = 1, lastConnectedAt = 9, forwards = listOf(forward))
        val edited = (read(SshHostForm.of(existing).copy(name = "New"), existing) as SshHostFormReading.Valid).host
        assertEquals(existing.copy(name = "New"), edited)
    }

    @Test
    fun aPrefixedStoreKeepsItsValuesApartFromTheOneItWraps() {
        val values = HashMap<String, String>()
        val inner = object : KeyValueStore {
            override fun read(key: String) = values[key]

            override fun write(key: String, value: String) {
                values[key] = value
            }
        }
        val ssh = PrefixedKeyValueStore(inner, "ssh_")
        ssh.write("terminal_quick_commands", "ls")
        assertEquals("ls", ssh.read("terminal_quick_commands"))
        assertNull(inner.read("terminal_quick_commands"))
        assertEquals("ls", inner.read("ssh_terminal_quick_commands"))
    }
}
