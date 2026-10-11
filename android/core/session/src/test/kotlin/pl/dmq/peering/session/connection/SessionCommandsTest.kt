package pl.dmq.peering.session.connection

import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.wire.AddVirtualDisplay
import pl.dmq.peering.wire.CaptureCatalog
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.JoystickMove
import pl.dmq.peering.wire.LockScreen
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.MouseMove
import pl.dmq.peering.wire.NormalizedPoint
import pl.dmq.peering.wire.OpenNewWindow
import pl.dmq.peering.wire.PushClipboardImage
import pl.dmq.peering.wire.QualityTier
import pl.dmq.peering.wire.RefreshSourceThumbnails
import pl.dmq.peering.wire.RemoteCommand
import pl.dmq.peering.wire.RemoveVirtualDisplay
import pl.dmq.peering.wire.RenameVirtualDisplay
import pl.dmq.peering.wire.ReportDeviceOrientation
import pl.dmq.peering.wire.Scroll
import pl.dmq.peering.wire.ServerHello
import pl.dmq.peering.wire.SetCaptureSource
import pl.dmq.peering.wire.SetStreamQuality
import pl.dmq.peering.wire.SetVideoEnabled
import pl.dmq.peering.wire.WatchSourceThumbnails

class SessionCommandsTest {
    private fun host(
        videoPause: Boolean? = null,
        mosaic: Boolean? = null,
        clipboardImages: Boolean? = null,
        virtualDisplays: Boolean? = null,
        thumbnails: Boolean? = null,
        orientation: Boolean? = null,
    ) = ServerHello(
        serverID = "MAC-STUDIO-01",
        hostName = "Studio",
        protocolVersion = 20,
        alreadyPaired = true,
        supportsVideoPause = videoPause,
        supportsMosaic = mosaic,
        supportsClipboardImages = clipboardImages,
        supportsVirtualDisplayManagement = virtualDisplays,
        supportsSourceThumbnails = thumbnails,
        supportsDeviceOrientation = orientation,
    )

    private val fullHost = host(true, true, true, true, true, true)
    private val bareHost = host()

    private fun guardedCommands(): List<Pair<RemoteCommand, HostCapability>> = listOf(
        SetVideoEnabled(false) to HostCapability.VideoPause,
        SetCaptureSource(CaptureSource.Mosaic(JsonObject(emptyMap()))) to HostCapability.Mosaic,
        PushClipboardImage("iVBORw0KGgo=") to HostCapability.ClipboardImages,
        AddVirtualDisplay("Phone", 1920, 1080, startLandscape = true) to HostCapability.VirtualDisplayManagement,
        RemoveVirtualDisplay(7) to HostCapability.VirtualDisplayManagement,
        RenameVirtualDisplay(7, "Desk") to HostCapability.VirtualDisplayManagement,
        WatchSourceThumbnails(true) to HostCapability.SourceThumbnails,
        RefreshSourceThumbnails to HostCapability.SourceThumbnails,
        ReportDeviceOrientation(isLandscape = true) to HostCapability.DeviceOrientation,
    )

    @Test
    fun aHostThatDeclaresEverythingAcceptsEveryGuardedCommand() {
        val commands = SessionCommands(fullHost)

        guardedCommands().forEach { (command, _) ->
            assertNotNull(command::class.simpleName, commands.send(command))
        }
        assertTrue(commands.takeRejections().isEmpty())
    }

    @Test
    fun aHostThatDeclaresNothingRefusesEachGuardedCommandAndNamesTheMissingCapability() {
        val commands = SessionCommands(bareHost)

        guardedCommands().forEach { (command, capability) ->
            assertNull(command::class.simpleName, commands.send(command))
            assertEquals(listOf(CommandRejection(command::class.simpleName!!, capability)), commands.takeRejections())
        }
    }

    @Test
    fun aHostWithOneFlagAcceptsOnlyThatFeature() {
        val commands = SessionCommands(host(videoPause = true))

        assertNotNull(commands.send(SetVideoEnabled(true)))
        assertNull(commands.send(RemoveVirtualDisplay(1)))
    }

    @Test
    fun aPlainCaptureSourceNeedsNoFlagButTheMosaicDoes() {
        val commands = SessionCommands(bareHost)

        assertNotNull(commands.send(SetCaptureSource(CaptureSource.Display(1))))
        assertNull(commands.send(SetCaptureSource(CaptureSource.Mosaic(JsonObject(emptyMap())))))
    }

    @Test
    fun unguardedCommandsAreSentToAnyHost() {
        val commands = SessionCommands(bareHost)

        assertNotNull(commands.send(LockScreen))
        assertNotNull(commands.send(OpenNewWindow("com.apple.Safari")))
        assertNotNull(commands.send(SetStreamQuality(fps = 0, bitrateKbps = 8000)))
        assertTrue(commands.takeRejections().isEmpty())
    }

    @Test
    fun aSentCommandParsesBackToTheSameCommand() {
        val commands = SessionCommands(fullHost)
        val command = RemoveVirtualDisplay(42)

        val frame = commands.send(command)!!

        assertEquals(MessageKind.Command, frame.kind)
        assertEquals(command, RemoteCommand.parse(frame.payload.decodeToString()))
    }

    @Test
    fun scrollInputAccumulatesIntoOneFrame() {
        val commands = SessionCommands(bareHost)

        commands.offer(Scroll(1.0, 2.0))
        commands.offer(Scroll(3.0, 4.0))

        val frames = commands.drain()
        assertEquals(1, frames.size)
        assertEquals(RemoteCommand.parse(frames.single().payload.decodeToString()), Scroll(4.0, 6.0))
    }

    @Test
    fun joystickInputAccumulatesIndependentlyOfScroll() {
        val commands = SessionCommands(bareHost)

        commands.offer(JoystickMove(0.5, 0.0))
        commands.offer(JoystickMove(0.5, -1.0))
        commands.offer(Scroll(1.0, 1.0))

        val parsed = commands.drain().map { RemoteCommand.parse(it.payload.decodeToString()) }
        assertEquals(listOf<RemoteCommand>(JoystickMove(1.0, -1.0), Scroll(1.0, 1.0)), parsed)
    }

    @Test
    fun aPointerMoveReplacesTheOneBeforeIt() {
        val commands = SessionCommands(bareHost)

        commands.offer(MouseMove(NormalizedPoint(0.1, 0.1)))
        commands.offer(MouseMove(NormalizedPoint(0.9, 0.2)))

        val parsed = commands.drain().map { RemoteCommand.parse(it.payload.decodeToString()) }
        assertEquals(listOf<RemoteCommand>(MouseMove(NormalizedPoint(0.9, 0.2))), parsed)
    }

    @Test
    fun aCommandTheHostCannotTakeIsNotQueued() {
        val commands = SessionCommands(bareHost)

        commands.offer(RemoveVirtualDisplay(3))

        assertTrue(commands.drain().isEmpty())
        assertEquals(1, commands.takeRejections().size)
    }

    @Test
    fun theFirstQualityIsTheTierBitrateWithFpsKeptAsItIs() {
        val commands = SessionCommands(bareHost)

        val command = commands.firstQualityCommand(QualityTier.MEDIUM)

        assertEquals(SetStreamQuality(fps = 0, bitrateKbps = 8_000), command)
        assertNotNull(commands.send(command))
    }

    @Test
    fun aCatalogueFrameIsDecodedAndKeptAsTheLatest() {
        val commands = SessionCommands(bareHost)
        val catalog = CaptureCatalog()

        val decoded = commands.onCatalog(Frame(MessageKind.Catalog, catalog.toJson().toByteArray()))

        assertEquals(catalog, decoded)
        assertEquals(catalog, commands.latestCatalog)
    }

    @Test
    fun aFrameThatIsNotACatalogueOrDoesNotParseGivesNoCatalogue() {
        val commands = SessionCommands(bareHost)

        assertNull(commands.onCatalog(Frame(MessageKind.Ping, "{}".toByteArray())))
        assertNull(commands.onCatalog(Frame(MessageKind.Catalog, "not json".toByteArray())))
        assertNull(commands.latestCatalog)
    }

    @Test
    fun takingRejectionsClearsThem() {
        val commands = SessionCommands(bareHost)
        commands.send(LockScreen)
        commands.send(RemoveVirtualDisplay(1))

        assertEquals(1, commands.takeRejections().size)
        assertTrue(commands.takeRejections().isEmpty())
    }
}
