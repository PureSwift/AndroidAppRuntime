package org.pureswift.appruntime.contracts

import android.app.PendingIntent
import android.content.Intent
import android.net.Uri
import android.os.Looper
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.SimpleBasePlayer
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import java.io.File
import java.io.IOException

/**
 * What's playing, for Swift's `AndroidNowPlaying` (Documentation/Plan.md
 * §6.13): one Media3 `MediaSession` for the app, over [NowPlayingPlayer],
 * which shows what Swift says and hands the buttons back to it. The
 * session lives in [NowPlayingService], which gives the notification, the
 * lock screen and the media buttons. With [background], the service is in
 * the foreground while it plays, so the app plays on. Main thread only.
 */
class NowPlayingSystem {

    /**
     * Shows what's playing. `commands`: bits, 1 next, 2 previous, 4
     * skipping. `duration` is negative for a live stream. Seconds.
     */
    fun show(
        title: String, artist: String, hasArtist: Boolean, album: String, hasAlbum: Boolean,
        commands: Int, skipBackward: Double, skipForward: Double,
        position: Double, duration: Double, rate: Float, playing: Boolean,
    ) {
        val player = player()
        player.shown = Shown(
            title, if (hasArtist) artist else null, if (hasAlbum) album else null,
            commands, skipBackward, skipForward, position, duration, rate, playing,
        )
        player.update()
        startService()
    }

    /** Shows nothing: the notification goes. */
    fun hide() {
        val player = current ?: return
        player.shown = null
        player.artwork = null
        player.update()
    }

    /**
     * The artwork: read once from `location`, a path, an `asset:///` URI
     * or a `content://` document, or `bytes` where there's no location.
     * Neither, no artwork.
     */
    fun artwork(location: String, bytes: ByteArray) {
        val player = player()
        player.artwork = when {
            location.isNotEmpty() -> read(location)
            bytes.isNotEmpty() -> bytes
            else -> null
        }
        player.update()
    }

    private fun read(location: String): ByteArray? {
        val context = HostContext.application
        return try {
            when {
                location.startsWith(ASSET) -> context.assets.open(location.removePrefix(ASSET)).use { it.readBytes() }
                location.startsWith("content:") -> context.contentResolver.openInputStream(Uri.parse(location))?.use { it.readBytes() }
                else -> File(location).readBytes()
            }
        } catch (error: IOException) {
            null
        } catch (error: SecurityException) {
            null
        }
    }

    /** Whether the service may hold the foreground while it plays. */
    fun setBackground(enabled: Boolean) {
        background = enabled
    }

    private fun player(): NowPlayingPlayer {
        current?.let { return it }
        val context = HostContext.application
        val player = NowPlayingPlayer()
        val builder = MediaSession.Builder(context, player).setId("org.pureswift.appruntime.nowplaying")
        context.packageManager.getLaunchIntentForPackage(context.packageName)?.let { launch ->
            builder.setSessionActivity(
                PendingIntent.getActivity(context, 0, launch, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            )
        }
        session = builder.build()
        current = player
        return player
    }

    /** The service, which shows the notification; started from the front. */
    private fun startService() {
        if (service != null) return
        val context = HostContext.application
        try {
            context.startService(Intent(context, NowPlayingService::class.java))
        } catch (error: IllegalStateException) {
            // In the background, where a service can't be started: the
            // session still takes the media buttons.
        } catch (error: SecurityException) {
        }
    }

    companion object {
        private const val ASSET = "asset:///"

        internal var current: NowPlayingPlayer? = null
        internal var session: MediaSession? = null
        internal var service: NowPlayingService? = null

        @Volatile internal var background = false
    }
}

/** What Swift last said, with the player's position. */
internal class Shown(
    val title: String, val artist: String?, val album: String?,
    val commands: Int, val skipBackward: Double, val skipForward: Double,
    val position: Double, val duration: Double, val rate: Float, val playing: Boolean,
)

/**
 * A player the session shows, which plays nothing itself: its state is what
 * Swift said, and what the session asks of it goes back to Swift, which
 * answers on the app's player. With next or previous offered, an item
 * stands on either side of what's playing, as Media3 offers those only
 * where there's an item to go to; going to it is the button.
 */
internal class NowPlayingPlayer : SimpleBasePlayer(Looper.getMainLooper()) {

    var shown: Shown? = null

    var artwork: ByteArray? = null

    fun update() = invalidateState()

    override fun getState(): State {
        val shown = shown ?: return State.Builder()
            .setAvailableCommands(Player.Commands.EMPTY)
            .setPlaybackState(Player.STATE_IDLE)
            .build()
        val next = shown.commands and 1 != 0
        val previous = shown.commands and 2 != 0
        val skip = shown.commands and 4 != 0
        val live = shown.duration < 0
        val metadata = MediaMetadata.Builder()
            // No display title: Android then describes it by its title,
            // artist and album.
            .setTitle(shown.title)
            .setArtist(shown.artist)
            .setAlbumTitle(shown.album)
            .apply { artwork?.let { setArtworkData(it, MediaMetadata.PICTURE_TYPE_FRONT_COVER) } }
            .build()
        val item = MediaItemData.Builder(CURRENT)
            .setMediaItem(MediaItem.Builder().setMediaId("current").setMediaMetadata(metadata).build())
            .setMediaMetadata(metadata)
            .setDurationUs(if (live) C.TIME_UNSET else (shown.duration * 1_000_000).toLong())
            .setIsSeekable(!live)
            .setIsDynamic(live)
            .build()
        val playlist = ArrayList<MediaItemData>()
        if (previous) playlist += MediaItemData.Builder(PREVIOUS).build()
        playlist += item
        if (next) playlist += MediaItemData.Builder(NEXT).build()

        val commands = Player.Commands.Builder().addAll(
            Player.COMMAND_PLAY_PAUSE, Player.COMMAND_GET_CURRENT_MEDIA_ITEM,
            Player.COMMAND_GET_TIMELINE, Player.COMMAND_GET_METADATA,
        )
        if (!live) commands.add(Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM)
        if (skip && !live) commands.addAll(Player.COMMAND_SEEK_BACK, Player.COMMAND_SEEK_FORWARD)
        if (next) commands.addAll(Player.COMMAND_SEEK_TO_NEXT, Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM)
        if (previous) commands.addAll(Player.COMMAND_SEEK_TO_PREVIOUS, Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM)

        val positionMs = (shown.position * 1000).toLong().coerceAtLeast(0)
        return State.Builder()
            .setAvailableCommands(commands.build())
            .setPlaylist(playlist)
            .setCurrentMediaItemIndex(if (previous) 1 else 0)
            .setContentPositionMs(
                if (shown.playing && !live) PositionSupplier.getExtrapolating(positionMs, shown.rate)
                else PositionSupplier.getConstant(positionMs)
            )
            .setPlaybackState(Player.STATE_READY)
            .setPlayWhenReady(shown.playing, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
            .setPlaybackParameters(PlaybackParameters(if (shown.rate > 0) shown.rate else 1f))
            .setSeekBackIncrementMs((shown.skipBackward * 1000).toLong().coerceAtLeast(1))
            .setSeekForwardIncrementMs((shown.skipForward * 1000).toLong().coerceAtLeast(1))
            .build()
    }

    override fun handleSetPlayWhenReady(playWhenReady: Boolean): ListenableFuture<*> {
        NowPlayingNatives.command(if (playWhenReady) PLAY else PAUSE, 0.0)
        return Futures.immediateVoidFuture()
    }

    override fun handleSeek(mediaItemIndex: Int, positionMs: Long, seekCommand: Int): ListenableFuture<*> {
        when (seekCommand) {
            Player.COMMAND_SEEK_TO_NEXT, Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM -> NowPlayingNatives.command(NEXT_TRACK, 0.0)
            Player.COMMAND_SEEK_TO_PREVIOUS, Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM -> NowPlayingNatives.command(PREVIOUS_TRACK, 0.0)
            Player.COMMAND_SEEK_BACK -> NowPlayingNatives.command(SKIP_BACKWARD, 0.0)
            Player.COMMAND_SEEK_FORWARD -> NowPlayingNatives.command(SKIP_FORWARD, 0.0)
            else -> NowPlayingNatives.command(SEEK, if (positionMs == C.TIME_UNSET) 0.0 else positionMs / 1000.0)
        }
        return Futures.immediateVoidFuture()
    }

    private companion object {
        const val CURRENT = "current"
        const val PREVIOUS = "previous"
        const val NEXT = "next"

        // The buttons, for `NowPlayingNatives.command`.
        const val PLAY = 0
        const val PAUSE = 1
        const val NEXT_TRACK = 2
        const val PREVIOUS_TRACK = 3
        const val SKIP_BACKWARD = 4
        const val SKIP_FORWARD = 5
        const val SEEK = 6
    }
}

/**
 * Holds the app's session: the notification, the lock screen and the
 * media buttons. The contracts module declares it; the packager adds
 * `foregroundServiceType="mediaPlayback"` for an app that plays in the
 * background, and only then is it in the foreground while it plays.
 */
class NowPlayingService : MediaSessionService() {

    override fun onCreate() {
        super.onCreate()
        NowPlayingSystem.service = this
        NowPlayingSystem.session?.let { addSession(it) }
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = NowPlayingSystem.session

    override fun onUpdateNotification(session: MediaSession, startInForegroundRequired: Boolean) {
        super.onUpdateNotification(session, startInForegroundRequired && NowPlayingSystem.background)
    }

    override fun onDestroy() {
        NowPlayingSystem.service = null
        super.onDestroy()
    }
}

/** The buttons, for Swift. Main thread. */
object NowPlayingNatives {

    /**
     * 0 play, 1 pause, 2 next, 3 previous, 4 skip back, 5 skip forward, 6
     * seek to `seconds`.
     */
    external fun command(command: Int, seconds: Double)
}
