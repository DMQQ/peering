package pl.dmq.peering.session.testing

import pl.dmq.peering.session.ports.DeviceIdentity

/** A fixed identity. Its signature is the reversed message, so a test can see exactly what was signed. */
class FakeIdentity(
    override val clientId: String = "00000000-0000-4000-8000-000000000001",
    override val publicKey: ByteArray = ByteArray(PUBLIC_KEY_SIZE) { 4 },
) : DeviceIdentity {
    override fun sign(message: ByteArray): ByteArray = message.reversedArray()

    private companion object {
        const val PUBLIC_KEY_SIZE = 65
    }
}
