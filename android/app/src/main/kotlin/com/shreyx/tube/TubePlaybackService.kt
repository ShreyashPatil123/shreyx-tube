package com.shreyx.tube

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService

/**
 * AndroidX Media3 MediaSessionService for ShreyX Tube background media playback.
 * Provides lock-screen media controls, Bluetooth / headset integration, and foreground
 * service lifecycle for normal video audio playback.
 */
class TubePlaybackService : MediaSessionService() {

    companion object {
        private const val TAG = "TubePlaybackService"
    }

    private var mediaSession: MediaSession? = null

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "TubePlaybackService onCreate: setting up MediaSession")

        val player = TubePlayerBridge.instance?.player
        if (player != null) {
            val intent = Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
            val pendingIntent = PendingIntent.getActivity(this, 0, intent, flags)

            mediaSession = MediaSession.Builder(this, player)
                .setSessionActivity(pendingIntent)
                .build()
            Log.i(TAG, "MediaSession successfully initialized for TubePlayerBridge ExoPlayer")
        } else {
            Log.w(TAG, "TubePlayerBridge instance or player was null during service creation")
        }
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? {
        // Return existing session or lazily build if player became available
        if (mediaSession == null) {
            val player = TubePlayerBridge.instance?.player
            if (player != null) {
                val intent = Intent(this, MainActivity::class.java)
                val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                } else {
                    PendingIntent.FLAG_UPDATE_CURRENT
                }
                val pendingIntent = PendingIntent.getActivity(this, 0, intent, flags)
                mediaSession = MediaSession.Builder(this, player)
                    .setSessionActivity(pendingIntent)
                    .build()
            }
        }
        return mediaSession
    }

    override fun onDestroy() {
        Log.i(TAG, "TubePlaybackService onDestroy: releasing MediaSession")
        mediaSession?.run {
            release()
            mediaSession = null
        }
        super.onDestroy()
    }
}
