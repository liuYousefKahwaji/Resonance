package com.example.resonance.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.RectF
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.KeyEvent
import android.view.View
import android.widget.RemoteViews
import android.support.v4.media.MediaBrowserCompat
import android.support.v4.media.session.MediaControllerCompat
import android.support.v4.media.session.PlaybackStateCompat
import androidx.media.session.MediaButtonReceiver
import com.example.resonance.MainActivity
import com.example.resonance.R
import com.ryanheise.audioservice.AudioService
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume
import kotlin.math.min
import kotlin.math.roundToInt

private const val WIDGET_CHANNEL = "resonance/playback_widget"
private const val WIDGET_PREFERENCES = "resonance_playback_widget"
private const val WIDGET_LOG_TAG = "ResonanceWidget"
private const val WIDGET_ACTION_PREFIX = "com.example.resonance.widget.PLAYBACK"

private data class PlaybackWidgetSnapshot(
    val hasTrack: Boolean = false,
    val title: String = "Nothing playing",
    val artist: String = "",
    val artworkPath: String = "",
    val playing: Boolean = false,
    val shuffle: Boolean = false,
    val repeatMode: String = "all",
    val accent: Int = 0xFF7C3AED.toInt(),
    val surface: Int = 0xFF1A1A24.toInt(),
    val surfaceElevated: Int = 0xFF242430.toInt(),
    val onSurface: Int = 0xFFE2E8F0.toInt(),
    val onSurfaceVariant: Int = 0xFF94A3B8.toInt(),
)

private object PlaybackWidgetStore {
    fun read(context: Context): PlaybackWidgetSnapshot {
        val preferences = context.getSharedPreferences(WIDGET_PREFERENCES, Context.MODE_PRIVATE)
        return PlaybackWidgetSnapshot(
            hasTrack = preferences.getBoolean("hasTrack", false),
            title = preferences.getString("title", null).orEmpty().ifBlank { "Nothing playing" },
            artist = preferences.getString("artist", null).orEmpty(),
            artworkPath = preferences.getString("artworkPath", null).orEmpty(),
            playing = preferences.getBoolean("playing", false),
            shuffle = preferences.getBoolean("shuffle", false),
            repeatMode = preferences.getString("repeatMode", "all") ?: "all",
            accent = preferences.getInt("accent", 0xFF7C3AED.toInt()),
            surface = preferences.getInt("surface", 0xFF1A1A24.toInt()),
            surfaceElevated = preferences.getInt("surfaceElevated", 0xFF242430.toInt()),
            onSurface = preferences.getInt("onSurface", 0xFFE2E8F0.toInt()),
            onSurfaceVariant = preferences.getInt("onSurfaceVariant", 0xFF94A3B8.toInt()),
        )
    }

    fun write(context: Context, values: Map<*, *>) {
        context.getSharedPreferences(WIDGET_PREFERENCES, Context.MODE_PRIVATE).edit().apply {
            putBoolean("hasTrack", values["hasTrack"] == true)
            putString("title", values["title"] as? String ?: "Nothing playing")
            putString("artist", values["artist"] as? String ?: "")
            putString("artworkPath", values["artworkPath"] as? String ?: "")
            putBoolean("playing", values["playing"] == true)
            putBoolean("shuffle", values["shuffle"] == true)
            putString("repeatMode", values["repeatMode"] as? String ?: "all")
            putInt("accent", (values["accent"] as? Number)?.toLong()?.toInt() ?: 0xFF7C3AED.toInt())
            putInt("surface", (values["surface"] as? Number)?.toLong()?.toInt() ?: 0xFF1A1A24.toInt())
            putInt(
                "surfaceElevated",
                (values["surfaceElevated"] as? Number)?.toLong()?.toInt() ?: 0xFF242430.toInt(),
            )
            putInt("onSurface", (values["onSurface"] as? Number)?.toLong()?.toInt() ?: 0xFFE2E8F0.toInt())
            putInt(
                "onSurfaceVariant",
                (values["onSurfaceVariant"] as? Number)?.toLong()?.toInt() ?: 0xFF94A3B8.toInt(),
            )
        }.apply()
    }

    fun updatePlaying(context: Context, playing: Boolean) {
        context.getSharedPreferences(WIDGET_PREFERENCES, Context.MODE_PRIVATE).edit()
            .putBoolean("playing", playing)
            .apply()
    }

    fun updateShuffle(context: Context, enabled: Boolean) {
        context.getSharedPreferences(WIDGET_PREFERENCES, Context.MODE_PRIVATE).edit()
            .putBoolean("shuffle", enabled)
            .apply()
    }

    fun updateRepeat(context: Context, mode: String) {
        context.getSharedPreferences(WIDGET_PREFERENCES, Context.MODE_PRIVATE).edit()
            .putString("repeatMode", mode)
            .apply()
    }
}

object ResonancePlaybackWidgetBridge {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile
    private var flutterChannel: MethodChannel? = null

    fun register(flutterEngine: FlutterEngine, context: Context) {
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WIDGET_CHANNEL)
        flutterChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "update" -> {
                    val values = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
                    PlaybackWidgetStore.write(context, values)
                    scope.launch {
                        runCatching {
                            PlaybackWidgetUpdater.updatePlacedWidgets(context)
                        }.onSuccess {
                            mainHandler.post { result.success(null) }
                        }.onFailure { error ->
                            Log.e(WIDGET_LOG_TAG, "Could not refresh widget snapshot", error)
                            mainHandler.post {
                                result.error("WIDGET_UPDATE_FAILED", error.message, null)
                            }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    suspend fun dispatchCommandToFlutter(commandName: String): Boolean {
        val channel = flutterChannel ?: return false
        if (commandName != "shuffle" && commandName != "repeat") return false
        return withContext(Dispatchers.Main.immediate) {
            withTimeoutOrNull(2_500) {
                suspendCancellableCoroutine { continuation ->
                    channel.invokeMethod("command", commandName, object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            if (continuation.isActive) continuation.resume(result == true)
                        }

                        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                            Log.w(WIDGET_LOG_TAG, "Flutter command $commandName failed: $errorCode $errorMessage")
                            if (continuation.isActive) continuation.resume(false)
                        }

                        override fun notImplemented() {
                            Log.w(WIDGET_LOG_TAG, "Flutter command bridge is unavailable for $commandName")
                            if (continuation.isActive) continuation.resume(false)
                        }
                    })
                }
            } ?: false
        }
    }
}

class ResonancePlaybackWidgetReceiver : AppWidgetProvider() {
    companion object {
        private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    }

    override fun onUpdate(context: Context, manager: AppWidgetManager, appWidgetIds: IntArray) {
        scope.launch { PlaybackWidgetUpdater.updateWidgets(context, appWidgetIds) }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        manager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: android.os.Bundle,
    ) {
        scope.launch { PlaybackWidgetUpdater.updateWidgets(context, intArrayOf(appWidgetId)) }
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        val command = PlaybackWidgetCommand.entries.firstOrNull {
            intent.action == "$WIDGET_ACTION_PREFIX.${it.name}"
        } ?: return
        val pendingResult = goAsync()
        scope.launch {
            try {
                runWidgetCommand(context, command)
            } finally {
                pendingResult.finish()
            }
        }
    }
}

private enum class WidgetLayout(val resource: Int) {
    COMPACT(R.layout.resonance_widget_compact),
    STANDARD(R.layout.resonance_widget_standard),
    EXPANDED(R.layout.resonance_widget_expanded),
}

private object PlaybackWidgetUpdater {
    private val updateMutex = Mutex()

    suspend fun updatePlacedWidgets(context: Context) {
        val appContext = context.applicationContext
        val component = ComponentName(appContext, ResonancePlaybackWidgetReceiver::class.java)
        val widgetIds = AppWidgetManager.getInstance(appContext).getAppWidgetIds(component)
        updateWidgets(appContext, widgetIds)
    }

    suspend fun updateWidgets(context: Context, widgetIds: IntArray) {
        updateMutex.withLock {
            val appContext = context.applicationContext
            val manager = AppWidgetManager.getInstance(appContext)
            val snapshot = PlaybackWidgetStore.read(appContext)
            Log.d(WIDGET_LOG_TAG, "Directly refreshing ${widgetIds.size} placed widget(s)")
            widgetIds.forEach { appWidgetId ->
                runCatching {
                    val options = manager.getAppWidgetOptions(appWidgetId)
                    val width = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 250)
                    val height = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 80)
                    val layout = when {
                        height >= 128 && width >= 220 -> WidgetLayout.EXPANDED
                        width >= 220 -> WidgetLayout.STANDARD
                        else -> WidgetLayout.COMPACT
                    }
                    manager.updateAppWidget(
                        appWidgetId,
                        buildRemoteViews(appContext, appWidgetId, width, height, layout, snapshot),
                    )
                }.onFailure { error ->
                    Log.e(WIDGET_LOG_TAG, "Widget $appWidgetId refresh failed", error)
                }
            }
        }
    }
}

private fun buildRemoteViews(
    context: Context,
    appWidgetId: Int,
    width: Int,
    height: Int,
    layout: WidgetLayout,
    snapshot: PlaybackWidgetSnapshot,
): RemoteViews {
    val views = RemoteViews(context.packageName, layout.resource)
    views.setImageViewBitmap(
        R.id.widget_background,
        roundedColorBitmap(context, width.coerceAtLeast(110), height.coerceAtLeast(56), 22f, snapshot.surface),
    )
    views.setTextViewText(R.id.widget_title, if (snapshot.hasTrack) snapshot.title else "Nothing playing")
    views.setTextColor(R.id.widget_title, snapshot.onSurface)
    views.setTextViewText(
        R.id.widget_artist,
        when {
            !snapshot.hasTrack -> "Tap to open Resonance"
            snapshot.artist.isBlank() -> ""
            else -> snapshot.artist
        },
    )
    views.setTextColor(R.id.widget_artist, snapshot.onSurfaceVariant)
    views.setViewVisibility(
        R.id.widget_artist,
        if (!snapshot.hasTrack || snapshot.artist.isNotBlank()) View.VISIBLE else View.GONE,
    )

    val openApp = openResonancePendingIntent(context)
    views.setOnClickPendingIntent(R.id.widget_metadata, openApp)

    if (layout != WidgetLayout.COMPACT) {
        val artworkSize = if (layout == WidgetLayout.EXPANDED) 70 else 54
        views.setImageViewBitmap(
            R.id.widget_artwork,
            artworkBitmap(context, snapshot, artworkSize),
        )
        views.setOnClickPendingIntent(R.id.widget_artwork, openApp)
    }

    val controlsVisible = if (snapshot.hasTrack) View.VISIBLE else View.INVISIBLE
    setControl(
        context,
        views,
        appWidgetId,
        R.id.widget_play_pause,
        if (snapshot.playing) R.drawable.ic_widget_pause else R.drawable.ic_widget_play,
        if (layout == WidgetLayout.COMPACT) 42 else if (layout == WidgetLayout.EXPANDED) 44 else 40,
        snapshot.accent,
        Color.WHITE,
        PlaybackWidgetCommand.PLAY_PAUSE,
        controlsVisible,
    )
    if (layout != WidgetLayout.COMPACT) {
        val transportSize = if (layout == WidgetLayout.EXPANDED) 38 else 34
        setControl(
            context,
            views,
            appWidgetId,
            R.id.widget_previous,
            R.drawable.ic_widget_previous,
            transportSize,
            Color.TRANSPARENT,
            snapshot.onSurfaceVariant,
            PlaybackWidgetCommand.PREVIOUS,
            controlsVisible,
        )
        setControl(
            context,
            views,
            appWidgetId,
            R.id.widget_next,
            R.drawable.ic_widget_next,
            transportSize,
            Color.TRANSPARENT,
            snapshot.onSurfaceVariant,
            PlaybackWidgetCommand.NEXT,
            controlsVisible,
        )
    }
    if (layout == WidgetLayout.EXPANDED) {
        val repeatSelected = snapshot.repeatMode != "off"
        setControl(
            context,
            views,
            appWidgetId,
            R.id.widget_repeat,
            if (snapshot.repeatMode == "one") R.drawable.ic_widget_repeat_one else R.drawable.ic_widget_repeat,
            38,
            if (repeatSelected) withAlpha(snapshot.accent, 0x33) else Color.TRANSPARENT,
            if (repeatSelected) snapshot.accent else snapshot.onSurfaceVariant,
            PlaybackWidgetCommand.REPEAT,
            controlsVisible,
        )
        setControl(
            context,
            views,
            appWidgetId,
            R.id.widget_shuffle,
            R.drawable.ic_widget_shuffle,
            38,
            if (snapshot.shuffle) withAlpha(snapshot.accent, 0x33) else Color.TRANSPARENT,
            if (snapshot.shuffle) snapshot.accent else snapshot.onSurfaceVariant,
            PlaybackWidgetCommand.SHUFFLE,
            controlsVisible,
        )
    }
    return views
}

private fun setControl(
    context: Context,
    views: RemoteViews,
    appWidgetId: Int,
    viewId: Int,
    icon: Int,
    sizeDp: Int,
    background: Int,
    foreground: Int,
    command: PlaybackWidgetCommand,
    visibility: Int,
) {
    views.setViewVisibility(viewId, visibility)
    views.setImageViewBitmap(viewId, controlBitmap(context, icon, sizeDp, background, foreground))
    views.setOnClickPendingIntent(viewId, commandPendingIntent(context, appWidgetId, command))
}

private fun openResonancePendingIntent(context: Context): PendingIntent {
    val intent = Intent(context, MainActivity::class.java).apply {
        action = Intent.ACTION_MAIN
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
    }
    return PendingIntent.getActivity(
        context,
        0,
        intent,
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
}

private fun commandPendingIntent(
    context: Context,
    appWidgetId: Int,
    command: PlaybackWidgetCommand,
): PendingIntent {
    val intent = Intent(context, ResonancePlaybackWidgetReceiver::class.java).apply {
        action = "$WIDGET_ACTION_PREFIX.${command.name}"
        putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
    }
    return PendingIntent.getBroadcast(
        context,
        appWidgetId * 10 + command.ordinal,
        intent,
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
}

private fun roundedColorBitmap(
    context: Context,
    widthDp: Int,
    heightDp: Int,
    radiusDp: Float,
    color: Int,
): Bitmap {
    val scale = min(context.resources.displayMetrics.density, 1.5f)
    val width = (widthDp * scale).roundToInt().coerceIn(1, 450)
    val height = (heightDp * scale).roundToInt().coerceIn(1, 240)
    return Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also { bitmap ->
        val canvas = Canvas(bitmap)
        val radius = radiusDp * scale
        canvas.drawRoundRect(
            RectF(0f, 0f, width.toFloat(), height.toFloat()),
            radius,
            radius,
            Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color },
        )
    }
}

private fun controlBitmap(
    context: Context,
    iconResource: Int,
    sizeDp: Int,
    background: Int,
    foreground: Int,
): Bitmap {
    val scale = min(context.resources.displayMetrics.density, 2f)
    val size = (sizeDp * scale).roundToInt().coerceAtLeast(1)
    return Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888).also { bitmap ->
        val canvas = Canvas(bitmap)
        if (Color.alpha(background) != 0) {
            canvas.drawCircle(
                size / 2f,
                size / 2f,
                size / 2f,
                Paint(Paint.ANTI_ALIAS_FLAG).apply { color = background },
            )
        }
        context.getDrawable(iconResource)?.mutate()?.let { drawable ->
            drawable.setTint(foreground)
            val iconSize = (size * 0.52f).roundToInt()
            val inset = (size - iconSize) / 2
            drawable.setBounds(inset, inset, inset + iconSize, inset + iconSize)
            drawable.draw(canvas)
        }
    }
}

private fun artworkBitmap(
    context: Context,
    snapshot: PlaybackWidgetSnapshot,
    sizeDp: Int,
): Bitmap {
    val scale = min(context.resources.displayMetrics.density, 2f)
    val size = (sizeDp * scale).roundToInt().coerceAtLeast(1)
    val output = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(output)
    val radius = 13f * scale
    val clipPath = Path().apply {
        addRoundRect(RectF(0f, 0f, size.toFloat(), size.toFloat()), radius, radius, Path.Direction.CW)
    }
    canvas.clipPath(clipPath)
    val decoded = snapshot.artworkPath
        .takeIf(String::isNotBlank)
        ?.let { BitmapFactory.decodeFile(it) }
    if (decoded != null) {
        val sourceSize = min(decoded.width, decoded.height)
        val sourceLeft = (decoded.width - sourceSize) / 2
        val sourceTop = (decoded.height - sourceSize) / 2
        canvas.drawBitmap(
            decoded,
            Rect(sourceLeft, sourceTop, sourceLeft + sourceSize, sourceTop + sourceSize),
            Rect(0, 0, size, size),
            Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG),
        )
        decoded.recycle()
    } else {
        canvas.drawColor(snapshot.surfaceElevated)
        context.getDrawable(R.drawable.ic_widget_artwork_fallback)?.mutate()?.let { drawable ->
            drawable.setTint(snapshot.onSurfaceVariant)
            val inset = (size * 0.2f).roundToInt()
            drawable.setBounds(inset, inset, size - inset, size - inset)
            drawable.draw(canvas)
        }
    }
    return output
}

private fun withAlpha(value: Int, alpha: Int) =
    (value and 0x00FFFFFF) or ((alpha and 0xFF) shl 24)

private enum class PlaybackWidgetCommand {
    PREVIOUS,
    PLAY_PAUSE,
    NEXT,
    SHUFFLE,
    REPEAT,
}

private object WidgetMediaController {
    suspend fun dispatch(context: Context, command: PlaybackWidgetCommand): Boolean {
        val flutterCommand = when (command) {
            PlaybackWidgetCommand.SHUFFLE -> "shuffle"
            PlaybackWidgetCommand.REPEAT -> "repeat"
            else -> null
        }
        if (
            flutterCommand != null &&
            ResonancePlaybackWidgetBridge.dispatchCommandToFlutter(flutterCommand)
        ) {
            return true
        }

        if (
            command == PlaybackWidgetCommand.PREVIOUS ||
            command == PlaybackWidgetCommand.PLAY_PAUSE ||
            command == PlaybackWidgetCommand.NEXT
        ) {
            val keyCode = when (command) {
                PlaybackWidgetCommand.PREVIOUS -> KeyEvent.KEYCODE_MEDIA_PREVIOUS
                PlaybackWidgetCommand.PLAY_PAUSE -> KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
                PlaybackWidgetCommand.NEXT -> KeyEvent.KEYCODE_MEDIA_NEXT
                else -> error("Unsupported media-button command")
            }
            return runCatching {
                sendMediaButton(context, keyCode)
                true
            }.onFailure { error ->
                Log.e(WIDGET_LOG_TAG, "Media button dispatch failed for $command", error)
            }.getOrDefault(false)
        }

        return withContext(Dispatchers.Main.immediate) {
            withTimeoutOrNull(2_500) {
                suspendCancellableCoroutine { continuation ->
                    lateinit var browser: MediaBrowserCompat
                    val callback = object : MediaBrowserCompat.ConnectionCallback() {
                        override fun onConnected() {
                            val snapshot = PlaybackWidgetStore.read(context)
                            val dispatched = runCatching {
                                val controls =
                                    MediaControllerCompat(context, browser.sessionToken).transportControls
                                when (command) {
                                    PlaybackWidgetCommand.SHUFFLE ->
                                        controls.setShuffleMode(
                                            if (snapshot.shuffle) {
                                                PlaybackStateCompat.SHUFFLE_MODE_NONE
                                            } else {
                                                PlaybackStateCompat.SHUFFLE_MODE_ALL
                                            },
                                        )
                                    PlaybackWidgetCommand.REPEAT ->
                                        controls.setRepeatMode(
                                            when (snapshot.repeatMode) {
                                                "off" -> PlaybackStateCompat.REPEAT_MODE_ONE
                                                "one" -> PlaybackStateCompat.REPEAT_MODE_ALL
                                                else -> PlaybackStateCompat.REPEAT_MODE_NONE
                                            },
                                        )
                                    else -> error("Transport commands do not use the browser")
                                }
                            }.onFailure { error ->
                                Log.e(WIDGET_LOG_TAG, "Media session dispatch failed for $command", error)
                            }.isSuccess
                            browser.disconnect()
                            if (continuation.isActive) continuation.resume(dispatched)
                        }

                        override fun onConnectionFailed() {
                            Log.w(WIDGET_LOG_TAG, "Media browser connection failed for $command")
                            if (continuation.isActive) continuation.resume(false)
                        }

                        override fun onConnectionSuspended() {
                            Log.w(WIDGET_LOG_TAG, "Media browser connection suspended for $command")
                            if (continuation.isActive) continuation.resume(false)
                        }
                    }
                    browser = MediaBrowserCompat(
                        context,
                        ComponentName(context, AudioService::class.java),
                        callback,
                        null,
                    )
                    continuation.invokeOnCancellation { browser.disconnect() }
                    browser.connect()
                }
            } ?: false
        }
    }

    private fun sendMediaButton(context: Context, keyCode: Int) {
        val receiver = ComponentName(context, MediaButtonReceiver::class.java)
        listOf(KeyEvent.ACTION_DOWN, KeyEvent.ACTION_UP).forEach { action ->
            context.sendBroadcast(
                Intent(Intent.ACTION_MEDIA_BUTTON)
                    .setComponent(receiver)
                    .putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(action, keyCode)),
            )
        }
    }
}

private suspend fun runWidgetCommand(context: Context, command: PlaybackWidgetCommand) {
    Log.d(WIDGET_LOG_TAG, "Widget action received: $command")
    val before = PlaybackWidgetStore.read(context)
    if (!before.hasTrack) return
    if (!WidgetMediaController.dispatch(context, command)) {
        Log.w(WIDGET_LOG_TAG, "Widget action was not dispatched: $command")
        return
    }
    when (command) {
        PlaybackWidgetCommand.PLAY_PAUSE ->
            PlaybackWidgetStore.updatePlaying(context, !before.playing)
        PlaybackWidgetCommand.SHUFFLE ->
            PlaybackWidgetStore.updateShuffle(context, !before.shuffle)
        PlaybackWidgetCommand.REPEAT -> {
            val next = when (before.repeatMode) {
                "off" -> "one"
                "one" -> "all"
                else -> "off"
            }
            PlaybackWidgetStore.updateRepeat(context, next)
        }
        PlaybackWidgetCommand.PREVIOUS,
        PlaybackWidgetCommand.NEXT,
        -> Unit
    }
    PlaybackWidgetUpdater.updatePlacedWidgets(context)
}
