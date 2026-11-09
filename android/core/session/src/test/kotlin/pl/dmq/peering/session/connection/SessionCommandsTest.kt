package pl.dmq.peering.session.connection

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.wire.CaptureCatalog
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.JoystickMove
import pl.dmq.peering.wire.LockScreen
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.MouseMove
import pl.dmq.peering.wire.NormalizedPoint
import pl.dmq.peering.wire.LaunchApplication
import pl.dmq.peering.wire.OpenNewWindow
import pl.dmq.peering.wire.PerformWindowAction
import pl.dmq.peering.wire.QualityTier
import pl.dmq.peering.wire.RefreshSpacePreviews
import pl.dmq.peering.wire.RemoteCommand
import pl.dmq.peering.wire.Scroll
import pl.dmq.peering.wire.ServerHello
import pl.dmq.peering.wire.SetPrivacyMode
import pl.dmq.peering.wire.SpaceDirection
import pl.dmq.peering.wire.SwitchSpace
import pl.dmq.peering.wire.SwitchToSpace
import pl.dmq.peering.wire.WindowAction
import pl.dmq.peering.wire.SetStreamQuality

class SessionCommandsTest {
    private val host = ServerHello(
        serverID = "MAC-STUDIO-01",
        hostName = "Studio",
        protocolVersion = 21,
        alreadyPaired = true,
    )
    private val windowsHost = host.copy(hostPlatform = "windows")

    @Test
    fun commandsWithNoPlatformRequirementAreSentToAnyHost() {
        val commands = SessionCommands(host)

        assertNotNull(commands.send(LockScreen))
        assertNotNull(commands.send(OpenNewWindow("com.apple.Safari")))
        assertNotNull(commands.send(SetStreamQuality(fps = 0, bitrateKbps = 8000)))
        assertTrue(commands.takeRejections().isEmpty())
    }

    @Test
    fun aSentCommandParsesBackToTheSameCommand() {
        val commands = SessionCommands(host)
        val command = SetStreamQuality(fps = 30, bitrateKbps = 4000)

        val frame = commands.send(command)!!

        assertEquals(MessageKind.Command, frame.kind)
        assertEquals(command, RemoteCommand.parse(frame.payload.decodeToString()))
    }

    @Test
    fun scrollInputAccumulatesIntoOneFrame() {
        val commands = SessionCommands(host)

        commands.offer(Scroll(1.0, 2.0))
        commands.offer(Scroll(3.0, 4.0))

        val frames = commands.drain()
        assertEquals(1, frames.size)
        assertEquals(RemoteCommand.parse(frames.single().payload.decodeToString()), Scroll(4.0, 6.0))
    }

    @Test
    fun joystickInputAccumulatesIndependentlyOfScroll() {
        val commands = SessionCommands(host)

        commands.offer(JoystickMove(0.5, 0.0))
        commands.offer(JoystickMove(0.5, -1.0))
        commands.offer(Scroll(1.0, 1.0))

        val parsed = commands.drain().map { RemoteCommand.parse(it.payload.decodeToString()) }
        assertEquals(listOf<RemoteCommand>(JoystickMove(1.0, -1.0), Scroll(1.0, 1.0)), parsed)
    }

    @Test
    fun aPointerMoveReplacesTheOneBeforeIt() {
        val commands = SessionCommands(host)

        commands.offer(MouseMove(NormalizedPoint(0.1, 0.1)))
        commands.offer(MouseMove(NormalizedPoint(0.9, 0.2)))

        val parsed = commands.drain().map { RemoteCommand.parse(it.payload.decodeToString()) }
        assertEquals(listOf<RemoteCommand>(MouseMove(NormalizedPoint(0.9, 0.2))), parsed)
    }

    @Test
    fun aCommandTheHostCannotTakeIsNotQueued() {
        val commands = SessionCommands(windowsHost)

        commands.offer(SwitchSpace(SpaceDirection.LEFT))

        assertTrue(commands.drain().isEmpty())
        assertEquals(1, commands.takeRejections().size)
    }

    @Test
    fun theFirstQualityIsTheTierBitrateWithFpsKeptAsItIs() {
        val commands = SessionCommands(host)

        val command = commands.firstQualityCommand(QualityTier.MEDIUM)

        assertEquals(SetStreamQuality(fps = 0, bitrateKbps = 8_000), command)
        assertNotNull(commands.send(command))
    }

    @Test
    fun aCatalogueFrameIsDecodedAndKeptAsTheLatest() {
        val commands = SessionCommands(host)
        val catalog = CaptureCatalog()

        val decoded = commands.onCatalog(Frame(MessageKind.Catalog, catalog.toJson().toByteArray()))

        assertEquals(catalog, decoded)
        assertEquals(catalog, commands.latestCatalog)
    }

    @Test
    fun aFrameThatIsNotACatalogueOrDoesNotParseGivesNoCatalogue() {
        val commands = SessionCommands(host)

        assertNull(commands.onCatalog(Frame(MessageKind.Ping, "{}".toByteArray())))
        assertNull(commands.onCatalog(Frame(MessageKind.Catalog, "not json".toByteArray())))
        assertNull(commands.latestCatalog)
    }

    private fun macOnlyCommands(): List<RemoteCommand> = listOf(
        SwitchSpace(SpaceDirection.LEFT),
        SwitchToSpace(1, 2),
        RefreshSpacePreviews,
        LaunchApplication("com.apple.Safari"),
        PerformWindowAction(7, WindowAction.CLOSE),
        OpenNewWindow("com.apple.Safari"),
        JoystickMove(0.5, 0.0),
    )

    @Test
    fun aWindowsHostRefusesEveryMacOnlyCommandAndNamesTheMissingCapability() {
        val commands = SessionCommands(windowsHost)

        macOnlyCommands().forEach { command ->
            assertNull(command::class.simpleName, commands.send(command))
            commands.offer(command)
        }
        assertEquals(macOnlyCommands().size * 2, commands.takeRejections().count { it.missing == HostCapability.MacControls })
        assertTrue(commands.drain().isEmpty())
    }

    @Test
    fun aMacAndAHostThatNamesNoPlatformAcceptEveryMacOnlyCommand() {
        listOf("macos", null).forEach { platform ->
            val commands = SessionCommands(host.copy(hostPlatform = platform))
            macOnlyCommands().forEach { assertNotNull(it::class.simpleName, commands.send(it)) }
        }
    }

    @Test
    fun aWindowsHostAcceptsLockAndDarken() {
        val commands = SessionCommands(windowsHost)

        assertNotNull(commands.send(LockScreen))
        assertNotNull(commands.send(SetPrivacyMode(true)))
    }

    @Test
    fun anUnknownPlatformRefusesLockAndDarken() {
        val commands = SessionCommands(host.copy(hostPlatform = "linux"))

        assertNull(commands.send(LockScreen))
        assertNull(commands.send(SetPrivacyMode(true)))
        assertEquals(2, commands.takeRejections().count { it.missing == HostCapability.ScreenControls })
    }

    @Test
    fun takingRejectionsClearsThem() {
        val commands = SessionCommands(windowsHost)
        commands.send(SwitchSpace(SpaceDirection.LEFT))

        assertEquals(1, commands.takeRejections().size)
        assertTrue(commands.takeRejections().isEmpty())
    }
}
