package pl.dmq.peering.platform.store

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PinStoreImplTest {
    private fun key(seed: Int): ByteArray = ByteArray(65) { (it + seed).toByte() }

    @Test
    fun recordedPinIsReadBack() {
        val store = PinStoreImpl(MemoryBlobStore())

        assertTrue(store.record("HOST-A", key(1)))

        assertArrayEquals(key(1), store.pin("HOST-A"))
    }

    @Test
    fun unknownHostHasNoPin() {
        assertNull(PinStoreImpl(MemoryBlobStore()).pin("NOBODY"))
    }

    @Test
    fun pinsSurviveANewStoreOverTheSameBlob() {
        val blobs = MemoryBlobStore()
        PinStoreImpl(blobs).record("HOST-A", key(1))

        assertArrayEquals(key(1), PinStoreImpl(blobs).pin("HOST-A"))
    }

    @Test
    fun removedHostIsForgottenAcrossStores() {
        val blobs = MemoryBlobStore()
        val store = PinStoreImpl(blobs)
        store.record("HOST-A", key(1))

        assertTrue(store.remove("HOST-A"))

        assertNull(store.pin("HOST-A"))
        assertNull(PinStoreImpl(blobs).pin("HOST-A"))
    }

    @Test
    fun failedRecordLeavesANewHostUnpinned() {
        val blobs = MemoryBlobStore().apply { failWrites = true }
        val store = PinStoreImpl(blobs)

        assertFalse(store.record("HOST-A", key(1)))

        assertNull(store.pin("HOST-A"))
    }

    @Test
    fun failedRecordRestoresThePreviousPin() {
        val blobs = MemoryBlobStore()
        val store = PinStoreImpl(blobs)
        store.record("HOST-A", key(1))
        blobs.failWrites = true

        assertFalse(store.record("HOST-A", key(2)))

        assertArrayEquals(key(1), store.pin("HOST-A"))
    }

    @Test
    fun failedRemoveKeepsThePin() {
        val blobs = MemoryBlobStore()
        val store = PinStoreImpl(blobs)
        store.record("HOST-A", key(1))
        blobs.failWrites = true

        assertFalse(store.remove("HOST-A"))

        assertArrayEquals(key(1), store.pin("HOST-A"))
    }

    @Test
    fun corruptBlobReadsAsNoPins() {
        val blobs = MemoryBlobStore().apply { blobs["pl.dmq.peering.pins"] = "{not json".toByteArray() }

        assertNull(PinStoreImpl(blobs).pin("HOST-A"))
    }

    @Test
    fun recordingOverACorruptBlobReplacesIt() {
        val blobs = MemoryBlobStore().apply { blobs["pl.dmq.peering.pins"] = byteArrayOf(0x00, 0x01) }
        val store = PinStoreImpl(blobs)

        assertTrue(store.record("HOST-A", key(1)))

        assertArrayEquals(key(1), PinStoreImpl(blobs).pin("HOST-A"))
    }

    @Test
    fun returnedPinCannotChangeTheStoredKey() {
        val store = PinStoreImpl(MemoryBlobStore())
        store.record("HOST-A", key(1))

        store.pin("HOST-A")!![0] = 0x7F

        assertArrayEquals(key(1), store.pin("HOST-A"))
    }

    @Test
    fun removingAnUnknownHostSucceeds() {
        assertTrue(PinStoreImpl(MemoryBlobStore()).remove("NOBODY"))
    }
}
