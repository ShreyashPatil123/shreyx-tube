package com.shreyx.tube

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.Rational
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.HttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.dash.DashMediaSource
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.MergingMediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import io.flutter.plugin.common.MethodChannel

/**
 * Native Media3 (ExoPlayer) playback bridge.
 * Supports progressive muxed streams, adaptive merging of 1080p+ video-only and audio streams,
 * DASH, HLS, seeking, and Picture-in-Picture.
 */
class TubePlayerBridge(private val context: Context) : Player.Listener {

    companion object {
        private const val TAG = "TubePlayerBridge"
        @Volatile
        var instance: TubePlayerBridge? = null
    }

    var player: ExoPlayer? = null
        private set

    var methodChannel: MethodChannel? = null
    var activity: Activity? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private var progressRunnable: Runnable? = null

    private var currentVideoWidth = 0
    private var currentVideoHeight = 0

    init {
        instance = this
        initPlayer()
    }

    private fun initPlayer() {
        if (player != null) return
        Log.i(TAG, "Initializing AndroidX Media3 ExoPlayer instance...")
        player = ExoPlayer.Builder(context).build().apply {
            addListener(this@TubePlayerBridge)
            playWhenReady = true
        }
        startProgressTracking()
    }

    private val dataSourceFactory: DefaultHttpDataSource.Factory by lazy {
        DefaultHttpDataSource.Factory()
            .setUserAgent(NoteNativeDownloader.USER_AGENT)
            .setConnectTimeoutMs(15000)
            .setReadTimeoutMs(20000)
            .setAllowCrossProtocolRedirects(true)
    }

    fun loadMedia(params: Map<String, Any?>): Map<String, Any?> {
        val videoUrl = params["videoUrl"] as? String ?: return mapOf("ok" to false, "message" to "No video URL")
        val audioUrl = params["audioUrl"] as? String
        val deliveryMethod = params["deliveryMethod"] as? String ?: "PROGRESSIVE"
        val mimeType = params["mimeType"] as? String
        val startPositionMs = (params["startPositionMs"] as? Number)?.toLong() ?: 0L
        val autoPlay = (params["autoPlay"] as? Boolean) ?: true

        val title = params["title"] as? String ?: "ShreyX Video"
        val channelTitle = params["channelTitle"] as? String ?: "YouTube"

        Log.i(TAG, "Loading Media: title=$title, deliveryMethod=$deliveryMethod, mimeType=$mimeType, hasAudio=${!audioUrl.isNullOrBlank()}, startPos=${startPositionMs}ms")
        Log.d(TAG, "Video URL: $videoUrl")
        if (!audioUrl.isNullOrBlank()) {
            Log.d(TAG, "Audio URL: $audioUrl")
        }

        try {
            val metadata = androidx.media3.common.MediaMetadata.Builder()
                .setTitle(title)
                .setArtist(channelTitle)
                .setDisplayTitle(title)
                .build()

            val mediaSource: MediaSource = when {
                // 1. HLS / Live
                deliveryMethod == "HLS" || mimeType?.contains("x-mpegURL", ignoreCase = true) == true -> {
                    Log.i(TAG, "Constructing HlsMediaSource")
                    HlsMediaSource.Factory(dataSourceFactory).createMediaSource(
                        MediaItem.Builder().setUri(videoUrl).setMediaMetadata(metadata).build()
                    )
                }
                // 2. DASH Manifest
                deliveryMethod == "DASH_MPD" || mimeType?.contains("dash+xml", ignoreCase = true) == true -> {
                    Log.i(TAG, "Constructing DashMediaSource")
                    DashMediaSource.Factory(dataSourceFactory).createMediaSource(
                        MediaItem.Builder().setUri(videoUrl).setMediaMetadata(metadata).build()
                    )
                }
                // 3. Adaptive Video-Only + Audio-Only (1080p, 1440p, 4K)
                !audioUrl.isNullOrBlank() -> {
                    Log.i(TAG, "Constructing MergingMediaSource for adaptive video + audio")
                    val videoSource = ProgressiveMediaSource.Factory(dataSourceFactory)
                        .createMediaSource(MediaItem.Builder().setUri(videoUrl).setMediaMetadata(metadata).build())
                    val audioSource = ProgressiveMediaSource.Factory(dataSourceFactory)
                        .createMediaSource(MediaItem.Builder().setUri(audioUrl).setMediaMetadata(metadata).build())
                    MergingMediaSource(videoSource, audioSource)
                }
                // 4. Progressive Muxed (360p / 720p)
                else -> {
                    Log.i(TAG, "Constructing ProgressiveMediaSource")
                    ProgressiveMediaSource.Factory(dataSourceFactory)
                        .createMediaSource(MediaItem.Builder().setUri(videoUrl).setMediaMetadata(metadata).build())
                }
            }

            player?.let { p ->
                p.stop()
                p.clearMediaItems()
                p.playlistMetadata = metadata
                p.setMediaSource(mediaSource)
                p.prepare()
                if (startPositionMs > 0) {
                    p.seekTo(startPositionMs)
                }
                p.playWhenReady = autoPlay
            }

            // Start background MediaSessionService for normal video audio continuity
            try {
                val serviceIntent = Intent(context, TubePlaybackService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(serviceIntent)
                } else {
                    context.startService(serviceIntent)
                }
            } catch (e: Exception) {
                Log.w(TAG, "Could not start TubePlaybackService: ${e.message}")
            }

            return mapOf("ok" to true)
        } catch (e: Exception) {
            Log.e(TAG, "Error loading media into Media3: ${e.message}", e)
            return mapOf("ok" to false, "message" to (e.message ?: "Failed to load media"))
        }
    }

    fun play() {
        player?.play()
    }

    fun pause() {
        player?.pause()
    }

    fun stop() {
        player?.stop()
        player?.clearMediaItems()
        try {
            context.stopService(Intent(context, TubePlaybackService::class.java))
        } catch (_: Exception) {}
    }

    fun seekTo(positionMs: Long) {
        player?.seekTo(positionMs)
    }

    fun setSpeed(speed: Float) {
        player?.setPlaybackSpeed(speed)
    }

    fun getStatus(): Map<String, Any?> {
        val p = player ?: return mapOf(
            "isPlaying" to false,
            "isBuffering" to false,
            "positionMs" to 0L,
            "durationMs" to 0L,
            "bufferedMs" to 0L,
            "videoWidth" to 0,
            "videoHeight" to 0
        )

        val duration = if (p.duration > 0) p.duration else 0L
        val position = if (p.currentPosition > 0) p.currentPosition else 0L
        val buffered = if (p.bufferedPosition > 0) p.bufferedPosition else 0L

        return mapOf(
            "isPlaying" to p.isPlaying,
            "isBuffering" to (p.playbackState == Player.STATE_BUFFERING),
            "playbackState" to stateToString(p.playbackState),
            "positionMs" to position,
            "durationMs" to duration,
            "bufferedMs" to buffered,
            "videoWidth" to currentVideoWidth,
            "videoHeight" to currentVideoHeight
        )
    }

    fun enterPip(): Boolean {
        val act = activity ?: return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val width = if (currentVideoWidth > 0) currentVideoWidth else 16
            val height = if (currentVideoHeight > 0) currentVideoHeight else 9
            val rational = Rational(width.coerceIn(1, 2390), height.coerceIn(1, 2390))
            val params = PictureInPictureParams.Builder()
                .setAspectRatio(rational)
                .build()
            return act.enterPictureInPictureMode(params)
        }
        return false
    }

    private fun stateToString(state: Int): String {
        return when (state) {
            Player.STATE_IDLE -> "IDLE"
            Player.STATE_BUFFERING -> "BUFFERING"
            Player.STATE_READY -> "READY"
            Player.STATE_ENDED -> "ENDED"
            else -> "UNKNOWN"
        }
    }

    private fun startProgressTracking() {
        stopProgressTracking()
        progressRunnable = object : Runnable {
            override fun run() {
                val p = player
                if (p != null && (p.isPlaying || p.playbackState == Player.STATE_BUFFERING)) {
                    val status = getStatus()
                    mainHandler.post {
                        methodChannel?.invokeMethod("onProgressUpdate", status)
                    }
                }
                mainHandler.postDelayed(this, 500)
            }
        }
        progressRunnable?.let { mainHandler.post(it) }
    }

    private fun stopProgressTracking() {
        progressRunnable?.let { mainHandler.removeCallbacks(it) }
        progressRunnable = null
    }

    // --- Player.Listener Implementation ---

    override fun onPlaybackStateChanged(playbackState: Int) {
        val stateStr = stateToString(playbackState)
        Log.i(TAG, "onPlaybackStateChanged: $stateStr (isPlaying=${player?.isPlaying})")
        mainHandler.post {
            methodChannel?.invokeMethod("onPlaybackStateChanged", mapOf(
                "state" to stateStr,
                "isPlaying" to (player?.isPlaying ?: false)
            ))
        }
    }

    override fun onIsPlayingChanged(isPlaying: Boolean) {
        Log.i(TAG, "onIsPlayingChanged: $isPlaying")
        mainHandler.post {
            methodChannel?.invokeMethod("onIsPlayingChanged", isPlaying)
        }
    }

    override fun onVideoSizeChanged(videoSize: VideoSize) {
        currentVideoWidth = videoSize.width
        currentVideoHeight = videoSize.height
        Log.i(TAG, "onVideoSizeChanged: ${videoSize.width}x${videoSize.height}")
        mainHandler.post {
            methodChannel?.invokeMethod("onVideoSizeChanged", mapOf(
                "width" to videoSize.width,
                "height" to videoSize.height,
                "pixelAspectRatio" to videoSize.pixelWidthHeightRatio
            ))
        }
    }

    override fun onPlayerError(error: PlaybackException) {
        val lastPos = player?.currentPosition ?: 0L
        val isHttpError = error.cause is HttpDataSource.HttpDataSourceException
        val httpCode = (error.cause as? HttpDataSource.InvalidResponseCodeException)?.responseCode ?: -1

        Log.e(TAG, "onPlayerError: code=${error.errorCode}, isHttp=$isHttpError, httpCode=$httpCode, pos=${lastPos}ms: ${error.message}", error)

        mainHandler.post {
            methodChannel?.invokeMethod("onPlaybackError", mapOf(
                "errorCode" to error.errorCodeName,
                "isHttpError" to isHttpError,
                "httpCode" to httpCode,
                "lastPositionMs" to lastPos,
                "message" to (error.message ?: "Playback error")
            ))
        }
    }

    fun release() {
        stopProgressTracking()
        player?.removeListener(this)
        player?.release()
        player = null
        instance = null
        Log.i(TAG, "TubePlayerBridge released")
    }
}
