package com.shreyx.tube

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : FlutterActivity() {

    private val scope = CoroutineScope(Dispatchers.Main)
    private var playerBridge: TubePlayerBridge? = null
    private var shortsPlayerBridge: TubeShortsPlayerBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 1. Initialize Media3 Player Bridge (Main Normal Player)
        val bridge = TubePlayerBridge(applicationContext)
        bridge.activity = this
        val playerChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.shreyx.tube/player_channel")
        bridge.methodChannel = playerChannel
        playerBridge = bridge

        // 2. Register PlatformView Factory for Media3 PlayerView (Main Player)
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "com.shreyx.tube/player_view",
            TubePlayerViewFactory(flutterEngine.dartExecutor.binaryMessenger)
        )

        // 3. Initialize Media3 Shorts Player Bridge & PlatformView
        val sBridge = TubeShortsPlayerBridge(applicationContext)
        val shortsChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.shreyx.tube/shorts_player_channel")
        sBridge.methodChannel = shortsChannel
        shortsPlayerBridge = sBridge

        flutterEngine.platformViewsController.registry.registerViewFactory(
            "com.shreyx.tube/shorts_player_view",
            TubeShortsPlayerViewFactory(flutterEngine.dartExecutor.binaryMessenger)
        )

        // 4. Extraction MethodChannel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.shreyx.tube/native_extractor")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "extractVideoStreams" -> {
                        val videoId = call.argument<String>("videoId") ?: ""
                        scope.launch {
                            val data = withContext(Dispatchers.IO) {
                                TubeExtractor.extract(videoId)
                            }
                            result.success(data)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // 5. Main Playback Control MethodChannel
        playerChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "loadMedia" -> {
                    @Suppress("UNCHECKED_CAST")
                    val params = call.arguments as? Map<String, Any?> ?: emptyMap()
                    val res = bridge.loadMedia(params)
                    result.success(res)
                }
                "play" -> {
                    bridge.play()
                    result.success(true)
                }
                "pause" -> {
                    bridge.pause()
                    result.success(true)
                }
                "seekTo" -> {
                    val pos = (call.argument<Number>("positionMs"))?.toLong() ?: 0L
                    bridge.seekTo(pos)
                    result.success(true)
                }
                "setSpeed" -> {
                    val speed = (call.argument<Double>("speed"))?.toFloat() ?: 1.0f
                    bridge.setSpeed(speed)
                    result.success(true)
                }
                "getStatus" -> {
                    result.success(bridge.getStatus())
                }
                "enterPip" -> {
                    result.success(bridge.enterPip())
                }
                else -> result.notImplemented()
            }
        }

        // 6. Shorts Playback Control MethodChannel
        shortsChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "loadMedia" -> {
                    @Suppress("UNCHECKED_CAST")
                    val params = call.arguments as? Map<String, Any?> ?: emptyMap()
                    val res = sBridge.loadMedia(params)
                    result.success(res)
                }
                "play" -> {
                    sBridge.play()
                    result.success(true)
                }
                "pause" -> {
                    sBridge.pause()
                    result.success(true)
                }
                "stop" -> {
                    sBridge.stop()
                    result.success(true)
                }
                "seekTo" -> {
                    val pos = (call.argument<Number>("positionMs"))?.toLong() ?: 0L
                    sBridge.seekTo(pos)
                    result.success(true)
                }
                "setMuted" -> {
                    val muted = call.argument<Boolean>("muted") ?: false
                    sBridge.setMuted(muted)
                    result.success(true)
                }
                "getStatus" -> {
                    result.success(sBridge.getStatus())
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (playerBridge?.player?.isPlaying == true) {
            playerBridge?.enterPip()
        }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: android.content.res.Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        playerBridge?.methodChannel?.invokeMethod("onPipModeChanged", isInPictureInPictureMode)
    }

    override fun onDestroy() {
        super.onDestroy()
        playerBridge?.release()
        playerBridge = null
        shortsPlayerBridge?.release()
        shortsPlayerBridge = null
    }
}
