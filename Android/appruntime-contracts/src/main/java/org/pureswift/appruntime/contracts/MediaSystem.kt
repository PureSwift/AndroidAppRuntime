package org.pureswift.appruntime.contracts

import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import java.io.File

/**
 * Media3's `ExoPlayer`s for Swift's `AndroidMediaEngine`s
 * (Documentation/Plan.md §6.10), by the identifier `HostMediaPlayback`
 * gives each. Swift decides; this class only drives the players and
 * reports what they do through [MediaNatives]. Main thread only.
 *
 * Each player takes audio focus as media does, and pauses when headphones
 * are unplugged; it says why it paused.
 */
class MediaSystem {

    private val context get() = HostContext.application

    /** Makes player `id`, with nothing loaded. */
    fun make(id: Int) {
        val player = ExoPlayer.Builder(context)
            .setAudioAttributes(
                AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(),
                /* handleAudioFocus = */ true,
            )
            .setHandleAudioBecomingNoisy(true)
            .build()
        val entry = Entry(id, player)
        player.addListener(entry)
        players[id] = entry
    }

    /**
     * Loads a path, an `asset:///` URI from the bundle, a `content://`
     * document, or an `http(s)` URL, paused at its start.
     */
    fun load(id: Int, location: String) {
        val entry = players[id] ?: return
        val uri = if (location.startsWith("/")) Uri.fromFile(File(location)) else Uri.parse(location)
        entry.begin()
        entry.player.setMediaItem(MediaItem.fromUri(uri))
        entry.player.playWhenReady = false
        entry.player.prepare()
    }

    /** Bytes in memory: written to a file of the app's cache, and loaded. */
    fun loadData(id: Int, bytes: ByteArray, extension: String) {
        val file = File(context.cacheDir, "rt-media-$id.$extension")
        try {
            file.writeBytes(bytes)
        } catch (error: java.io.IOException) {
            MediaNatives.failed(id, 0, "the data can't be kept: ${error.message}")
            return
        }
        load(id, file.absolutePath)
    }

    fun unload(id: Int) {
        val entry = players[id] ?: return
        entry.loaded = false
        entry.player.stop()
        entry.player.clearMediaItems()
        entry.stopTicking()
    }

    fun play(id: Int) {
        players[id]?.player?.play()
    }

    fun pause(id: Int) {
        players[id]?.let {
            it.pausing = true
            it.player.pause()
        }
    }

    /** Seconds; answered by `MediaNatives.seeked` with `request`. */
    fun seek(id: Int, seconds: Double, request: Int) {
        val entry = players[id] ?: return
        entry.seekRequest = request
        entry.player.seekTo((seconds * 1000).toLong().coerceAtLeast(0))
    }

    /** Where playback is, in seconds. */
    fun position(id: Int): Double = (players[id]?.player?.currentPosition ?: 0) / 1000.0

    fun setRate(id: Int, rate: Float) {
        if (rate > 0) players[id]?.player?.playbackParameters = PlaybackParameters(rate)
    }

    fun setVolume(id: Int, volume: Float) {
        val entry = players[id] ?: return
        entry.volume = volume.coerceIn(0f, 1f)
        if (!entry.muted) entry.player.volume = entry.volume
    }

    fun setMuted(id: Int, muted: Boolean) {
        val entry = players[id] ?: return
        entry.muted = muted
        entry.player.volume = if (muted) 0f else entry.volume
    }

    fun setLooping(id: Int, looping: Boolean) {
        players[id]?.player?.repeatMode = if (looping) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
    }

    /** How often, in milliseconds, the time is said while playing. */
    fun setTimeUpdateInterval(id: Int, milliseconds: Long) {
        val entry = players[id] ?: return
        entry.interval = milliseconds.coerceAtLeast(16)
        if (entry.player.isPlaying) entry.startTicking()
    }

    /** Lets player `id` go: the guest released it. */
    fun release(id: Int) {
        val entry = players.remove(id) ?: return
        entry.stopTicking()
        entry.player.release()
        File(context.cacheDir, "rt-media-$id").parentFile?.listFiles { file -> file.name.startsWith("rt-media-$id.") }?.forEach { it.delete() }
    }

    /** 0 no, 1 maybe, 2 probably. */
    fun canPlay(mimeType: String): Int {
        val type = mimeType.substringBefore(';').trim().lowercase()
        return when (type) {
            in PROBABLY -> 2
            in MAYBE -> 1
            else -> 0
        }
    }

    /** One player, and what Swift has been told of it. */
    private class Entry(val id: Int, val player: ExoPlayer) : Player.Listener {

        /** Whether `loaded` was said for the source. */
        var loaded = false

        /** A pause the guest asked for, which isn't the user's. */
        var pausing = false

        var seekRequest: Int? = null

        var volume = 1f

        var muted = false

        var interval = 250L

        private val handler = Handler(Looper.getMainLooper())

        private val tick = object : Runnable {
            override fun run() {
                sayTime()
                handler.postDelayed(this, interval)
            }
        }

        fun begin() {
            loaded = false
            seekRequest = null
            stopTicking()
        }

        fun startTicking() {
            handler.removeCallbacks(tick)
            handler.post(tick)
        }

        fun stopTicking() {
            handler.removeCallbacks(tick)
        }

        fun sayTime() {
            val rate = if (player.isPlaying) player.playbackParameters.speed else 0f
            MediaNatives.time(id, player.currentPosition / 1000.0, rate)
            MediaNatives.buffer(id, player.totalBufferedDuration / 1000.0)
        }

        override fun onPlaybackStateChanged(state: Int) {
            when (state) {
                Player.STATE_READY -> {
                    if (!loaded) {
                        loaded = true
                        val duration = player.duration.takeIf { it != C.TIME_UNSET && !player.isCurrentMediaItemLive }
                        val video = player.videoSize
                        val tracks = player.currentTracks
                        MediaNatives.loaded(
                            id, duration?.let { it / 1000.0 } ?: -1.0, video.width, video.height,
                            tracks.containsType(C.TRACK_TYPE_AUDIO), tracks.containsType(C.TRACK_TYPE_VIDEO),
                        )
                    }
                    report()
                }
                Player.STATE_BUFFERING -> if (loaded) report()
                Player.STATE_ENDED -> if (loaded) {
                    stopTicking()
                    sayTime()
                    MediaNatives.ended(id)
                }
                else -> {}
            }
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            if (!loaded) return
            report()
            if (isPlaying) startTicking() else {
                stopTicking()
                sayTime()
            }
        }

        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
            if (!loaded || playWhenReady) return
            val why = when (reason) {
                Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS -> REASON_INTERRUPTED
                Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_BECOMING_NOISY -> REASON_ROUTE_CHANGED
                Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST -> if (pausing) REASON_REQUESTED else REASON_USER
                else -> REASON_REQUESTED
            }
            pausing = false
            if (player.playbackState != Player.STATE_ENDED) {
                MediaNatives.state(id, STATE_PAUSED, why)
            }
        }

        /** Playing, or waiting for data to play. A pause is `onPlayWhenReadyChanged`'s. */
        private fun report() {
            if (player.isPlaying) {
                MediaNatives.state(id, STATE_PLAYING, 0)
            } else if (player.playWhenReady && player.playbackState == Player.STATE_BUFFERING) {
                MediaNatives.state(id, STATE_BUFFERING, 0)
            }
        }

        override fun onPositionDiscontinuity(old: Player.PositionInfo, new: Player.PositionInfo, reason: Int) {
            if (!loaded) return
            if (reason == Player.DISCONTINUITY_REASON_SEEK) {
                seekRequest?.let {
                    seekRequest = null
                    MediaNatives.seeked(id, it, true)
                }
            }
            // A seek, or a loop back to the start.
            sayTime()
        }

        override fun onPlayerError(error: PlaybackException) {
            stopTicking()
            val code = when (error.errorCode) {
                PlaybackException.ERROR_CODE_IO_FILE_NOT_FOUND,
                PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS -> ERROR_NOT_FOUND
                PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED,
                PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT -> ERROR_NETWORK
                PlaybackException.ERROR_CODE_IO_NO_PERMISSION,
                PlaybackException.ERROR_CODE_IO_CLEARTEXT_NOT_PERMITTED -> ERROR_NOT_PERMITTED
                PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED,
                PlaybackException.ERROR_CODE_PARSING_MANIFEST_UNSUPPORTED,
                PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED,
                PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES -> ERROR_UNSUPPORTED
                PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED,
                PlaybackException.ERROR_CODE_PARSING_MANIFEST_MALFORMED,
                PlaybackException.ERROR_CODE_DECODING_FAILED -> ERROR_DECODING
                PlaybackException.ERROR_CODE_AUDIO_TRACK_INIT_FAILED -> ERROR_UNAVAILABLE
                else -> ERROR_UNKNOWN
            }
            MediaNatives.failed(id, code, error.message ?: error.errorCodeName)
        }
    }

    companion object {

        private val players = HashMap<Int, Entry>()

        /** Player `id`, for a `VideoPlayer` node to show. */
        fun player(id: Int): ExoPlayer? = players[id]?.player

        // MediaState raw values.
        private const val STATE_PAUSED = 2
        private const val STATE_PLAYING = 3
        private const val STATE_BUFFERING = 4

        // MediaPauseReason raw values.
        private const val REASON_REQUESTED = 0
        private const val REASON_USER = 1
        private const val REASON_INTERRUPTED = 2
        private const val REASON_ROUTE_CHANGED = 6

        // MediaError.Code raw values.
        private const val ERROR_UNKNOWN = 0
        private const val ERROR_NOT_FOUND = 1
        private const val ERROR_UNSUPPORTED = 2
        private const val ERROR_NETWORK = 3
        private const val ERROR_NOT_PERMITTED = 4
        private const val ERROR_DECODING = 5
        private const val ERROR_UNAVAILABLE = 6

        /** What every host plays, and Media3 plays everywhere. */
        private val PROBABLY = setOf(
            "audio/mpeg", "audio/mp3", "audio/mp4", "audio/m4a", "audio/x-m4a", "audio/aac",
            "audio/wav", "audio/x-wav", "audio/wave", "video/mp4", "video/x-m4v", "video/quicktime",
        )

        /** What Media3 reads, where the device has the decoder. */
        private val MAYBE = setOf(
            "audio/ogg", "audio/opus", "audio/flac", "audio/webm", "video/webm", "video/x-matroska",
            "audio/x-matroska", "video/3gpp", "audio/3gpp", "audio/amr",
        )
    }
}

/** What the players do, for Swift. Main thread. */
object MediaNatives {

    external fun loaded(id: Int, duration: Double, width: Int, height: Int, hasAudio: Boolean, hasVideo: Boolean)

    /** A `MediaState`, and for a pause its `MediaPauseReason`. */
    external fun state(id: Int, state: Int, reason: Int)

    external fun time(id: Int, position: Double, rate: Float)

    external fun buffer(id: Int, seconds: Double)

    external fun seeked(id: Int, request: Int, finished: Boolean)

    external fun ended(id: Int)

    external fun failed(id: Int, code: Int, message: String)
}
