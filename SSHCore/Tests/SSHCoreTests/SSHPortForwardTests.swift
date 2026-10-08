import Foundation
import Testing

@testable import SSHCore

@Suite("Port forwards")
struct SSHPortForwardTests {
    private func read(
        label: String = "",
        local: String,
        remote: String = "db.internal",
        port: String,
        existing: [SSHPortForward] = [],
        ignoring: UUID? = nil
    ) -> Result<SSHPortForward, SSHPortForwardError> {
        SSHPortForward.reading(
            label: label,
            localPort: local,
            remoteHost: remote,
            remotePort: port,
            existing: existing,
            ignoring: ignoring
        )
    }

    @Test("a complete spec reads into a forward")
    func acceptsAWholeSpec() throws {
        let forward = try read(label: "  Database  ", local: "5432", remote: "  db.internal ", port: "5432").get()

        #expect(forward.localPort == 5432)
        #expect(forward.remotePort == 5432)
        #expect(forward.remoteHost == "db.internal")
        #expect(forward.label == "Database")
        #expect(forward.isEnabled)
    }

    @Test("the row says which end is which, including the local one")
    func display() {
        let named = SSHPortForward(label: "Database", localPort: 5432, remoteHost: "db.internal", remotePort: 5432)
        #expect(named.displayName == "Database")
        #expect(named.detail == "localhost:5432 → db.internal:5432")

        let unnamed = SSHPortForward(localPort: 8080, remoteHost: "web.internal", remotePort: 80)
        #expect(unnamed.displayName == "8080 → web.internal:80")
    }

    /// A helper rather than `if case`: an enum case with a payload is not a property, so `result.failure` does not compile.
    private func refusal(_ result: Result<SSHPortForward, SSHPortForwardError>) -> SSHPortForwardError? {
        guard case .failure(let error) = result else { return nil }
        return error
    }

    @Test("each field says what is wrong with it rather than the form saying something is")
    func fieldLevelRefusals() {
        #expect(refusal(read(local: "", port: "80")) == .localPortNotANumber)
        #expect(refusal(read(local: "http", port: "80")) == .localPortNotANumber)
        #expect(refusal(read(local: "0", port: "80")) == .localPortOutOfRange)
        #expect(refusal(read(local: "65536", port: "80")) == .localPortOutOfRange)
        #expect(refusal(read(local: "8080", remote: "  ", port: "80")) == .remoteHostEmpty)
        #expect(refusal(read(local: "8080", port: "")) == .remotePortNotANumber)
        #expect(refusal(read(local: "8080", port: "0")) == .remotePortOutOfRange)
        #expect(refusal(read(local: "8080", port: "70000")) == .remotePortOutOfRange)
    }

    @Test("a command line pasted into the host field is refused before it reaches a server")
    func aCommandLineIsNotAHost() {
        // A user pasting a whole `ssh -L ...` command from a tutorial into the middle field.
        let pasted = read(local: "8080", remote: "db.internal:5432 user@box", port: "5432")
        #expect(refusal(pasted) == .remoteHostNotAHostname)
        #expect(SSHPortForwardError.remoteHostNotAHostname.message.contains("hostname"))
    }

    @Test("an address and a name with awkward characters are both accepted")
    func hostnamesAreReadLoosely() throws {
        #expect(try read(local: "8080", remote: "10.0.0.4", port: "80").get().remoteHost == "10.0.0.4")
        #expect(try read(local: "8080", remote: "::1", port: "80").get().remoteHost == "::1")
        #expect(try read(local: "8080", remote: "db_1.internal", port: "80").get().remoteHost == "db_1.internal")
    }

    @Test("two forwards on one local port is refused, and says which port")
    func duplicateLocalPorts() {
        let taken = SSHPortForward(localPort: 8080, remoteHost: "web.internal", remotePort: 80)
        let result = read(local: "8080", port: "443", existing: [taken])

        #expect(refusal(result) == .localPortAlreadyUsed(8080))
        #expect(SSHPortForwardError.localPortAlreadyUsed(8080).message.contains("8080"))
    }

    @Test("editing a forward does not collide with itself")
    func editingIsNotADuplicate() throws {
        let existing = SSHPortForward(localPort: 8080, remoteHost: "web.internal", remotePort: 80)

        // Editing the far end is common, and counting the row being edited would refuse it.
        let edited = try read(local: "8080", remote: "other.internal", port: "443",
                              existing: [existing], ignoring: existing.id).get()

        #expect(edited.id == existing.id)
        #expect(edited.remoteHost == "other.internal")
        #expect(edited.isEnabled == existing.isEnabled)
    }

    @Test("a forward turned off stays off through an edit")
    func enabledSurvives() throws {
        let off = SSHPortForward(localPort: 8080, remoteHost: "web.internal", remotePort: 80, isEnabled: false)
        let edited = try read(local: "8080", remote: "web.internal", port: "8081",
                              existing: [off], ignoring: off.id).get()
        #expect(!edited.isEnabled)
    }

    @Test("the state of a forward reads as a sentence for the row")
    func stateSummary() {
        #expect(SSHForwardState.stopped.summary == "Stopped")
        #expect(SSHForwardState.starting.summary == "Starting")
        #expect(SSHForwardState.running(problem: nil).summary == "Running")
        #expect(SSHForwardState.running(problem: "refused").summary == "refused")
        #expect(SSHForwardState.failed("in use").summary == "in use")
        #expect(SSHForwardState.running(problem: nil).isRunning)
        #expect(!SSHForwardState.failed("in use").isRunning)
    }
}

@Suite("Forwards on a saved host")
struct SSHHostForwardTests {
    private func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "peering.ssh.forwards.\(UUID().uuidString)")!
    }

    @Test("a host carries its forwards through storage")
    func roundTrip() {
        let store = SSHHostStore(defaults: scratchDefaults())
        let forward = SSHPortForward(label: "Database", localPort: 5432, remoteHost: "db.internal", remotePort: 5432)
        let host = SSHHost(hostname: "box.local", username: "root", forwards: [forward])

        store.save([host])

        #expect(store.load() == [host])
        #expect(store.load().first?.forwards.first?.id == forward.id)
    }

    @Test("a host saved before forwards existed still loads")
    func aHostFromThePreviousBuild() {
        // The shape the previous build produced, with no `forwards` key: a missing key throws and `load()` would return an empty list.
        let defaults = scratchDefaults()
        let json = """
        [{"id":"\(UUID().uuidString)","name":"Prod","hostname":"box.local","port":22,\
        "username":"root","createdAt":700000000}]
        """
        defaults.set(Data(json.utf8), forKey: SSHHostStore.key)

        let hosts = SSHHostStore(defaults: defaults).load()
        #expect(hosts.count == 1)
        #expect(hosts.first?.hostname == "box.local")
        #expect(hosts.first?.forwards.isEmpty == true)
    }

    @Test("a host that never had a forward is not equal to one that has an empty list")
    func emptyIsTheDefault() {
        let explicit = SSHHost(hostname: "box.local", username: "root", forwards: [])
        let implicit = SSHHost(hostname: "box.local", username: "root")
        #expect(explicit.forwards == implicit.forwards)
    }
}
