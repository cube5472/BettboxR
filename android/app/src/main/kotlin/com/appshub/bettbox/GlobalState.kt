package com.appshub.bettbox

import android.content.ComponentName
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.service.quicksettings.TileService
import com.appshub.bettbox.plugins.AppPlugin
import com.appshub.bettbox.plugins.ServicePlugin
import com.appshub.bettbox.plugins.TilePlugin
import com.appshub.bettbox.plugins.VpnPlugin
import com.appshub.bettbox.services.BettboxTileService
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugins.GeneratedPluginRegistrant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

enum class RunState {
    START,
    PENDING,
    STOP
}

object GlobalState {
    val runLock = ReentrantLock()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val mainHandler = Handler(Looper.getMainLooper())

    const val NOTIFICATION_CHANNEL = "Bettbox"
    const val NOTIFICATION_CHANNEL_HIGH = "Bettbox_High"
    const val NOTIFICATION_CHANNEL_SUSPENDED = "Bettbox_Suspended"
    const val NOTIFICATION_ID = 1

    const val NOTIFICATION_ACTION_STOP = "com.appshub.bettbox.action.NOTIFICATION_STOP"
    const val NOTIFICATION_ACTION_RESTART = "com.appshub.bettbox.action.NOTIFICATION_RESTART"
    const val NOTIFICATION_ACTION_START = "com.appshub.bettbox.action.NOTIFICATION_START"
    const val NOTIFICATION_ACTION_PAUSE = "com.appshub.bettbox.action.NOTIFICATION_PAUSE"

    private const val PAUSE_PREFS_KEY = "pause_until_ts"
    private const val PAUSE_LAST_MINUTES_KEY = "pause_last_minutes"

    private const val TOGGLE_DEBOUNCE_MS = 1000L
    private const val PENDING_TIMEOUT_MS = 5000L
    private const val STOP_LOCK_TIMEOUT_MS = 5000L
    private const val RESTART_WAIT_TIMEOUT_MS = 15000L

    @Volatile
    private var lastToggleAt = 0L

    @Volatile
    var currentRunState: RunState = RunState.STOP
        private set

    private val _runState = MutableStateFlow(RunState.STOP)
    val runState = _runState.asStateFlow()

    private var pendingTimeoutJob: Job? = null

    var flutterEngine: FlutterEngine? = null
    private var serviceEngine: FlutterEngine? = null

    @Volatile
    var isSmartStopped = false

    @Volatile
    var isStopping = false

    @Volatile
    var currentProfileName: String = ""
        set(value) {
            if (field != value) {
                field = value
                requestTileUpdate()
            }
        }

    @Volatile
    var isSpeedNotificationEnabled: Boolean = false
        set(value) {
            if (field != value) {
                field = value
                requestTileUpdate()
            }
        }

    @Volatile
    var isNotificationHighPriority: Boolean = false

    /// Активная пауза VPN: epoch-ms момента автовозобновления (0 — паузы нет).
    /// Дублируется в SharedPreferences, чтобы будильник/перезапуск процесса
    /// не потеряли состояние.
    @Volatile
    var pauseUntilWallClock: Long = 0L
        private set

    fun isPaused(): Boolean =
        pauseUntilWallClock > System.currentTimeMillis()

    fun setPauseUntil(timestampMs: Long) {
        pauseUntilWallClock = timestampMs
        runCatching {
            BettboxApplication.getAppContext()
                .getSharedPreferences("vpn_state", android.content.Context.MODE_PRIVATE)
                .edit()
                .putLong(PAUSE_PREFS_KEY, timestampMs)
                .apply()
        }
    }

    fun clearPause() {
        pauseUntilWallClock = 0L
        runCatching {
            BettboxApplication.getAppContext()
                .getSharedPreferences("vpn_state", android.content.Context.MODE_PRIVATE)
                .edit()
                .remove(PAUSE_PREFS_KEY)
                .apply()
        }
    }

    /// Восстановить паузу после пересоздания движка (процесс жив, состояние слетело).
    fun restorePauseFromPrefs() {
        if (pauseUntilWallClock != 0L) return
        runCatching {
            val ts = BettboxApplication.getAppContext()
                .getSharedPreferences("vpn_state", android.content.Context.MODE_PRIVATE)
                .getLong(PAUSE_PREFS_KEY, 0L)
            if (ts > System.currentTimeMillis()) {
                pauseUntilWallClock = ts
            } else if (ts != 0L) {
                clearPause()
            }
        }
    }

    fun getLastPauseMinutes(): Int {
        return runCatching {
            BettboxApplication.getAppContext()
                .getSharedPreferences("vpn_state", android.content.Context.MODE_PRIVATE)
                .getInt(PAUSE_LAST_MINUTES_KEY, 15)
        }.getOrDefault(15).coerceIn(1, 24 * 60)
    }

    fun setLastPauseMinutes(minutes: Int) {
        runCatching {
            BettboxApplication.getAppContext()
                .getSharedPreferences("vpn_state", android.content.Context.MODE_PRIVATE)
                .edit()
                .putInt(PAUSE_LAST_MINUTES_KEY, minutes)
                .apply()
        }
    }

    fun updateRunState(newState: RunState) {
        if (currentRunState == newState) return

        if (newState != RunState.PENDING) {
            pendingTimeoutJob?.cancel()
            pendingTimeoutJob = null
        }
        currentRunState = newState
        _runState.value = newState
        requestTileUpdate()
    }

    private val tileRetryRunnable = Runnable {
        BettboxTileService.refreshActive()
        requestListeningStateSafely()
    }

    fun requestTileUpdate() {
        mainHandler.post {
            BettboxTileService.refreshActive()
            requestListeningStateSafely()
            mainHandler.removeCallbacks(tileRetryRunnable)
            mainHandler.postDelayed(tileRetryRunnable, 1000L)
        }
    }

    private fun requestListeningStateSafely() {
        runCatching {
            val context = BettboxApplication.getAppContext()
            TileService.requestListeningState(
                context,
                ComponentName(context, BettboxTileService::class.java)
            )
        }.onFailure {
            android.util.Log.w("GlobalState", "requestTileUpdate failed: ${it.message}")
        }
    }

    private fun startPendingTimeout() {
        pendingTimeoutJob?.cancel()
        pendingTimeoutJob = scope.launch {
            delay(PENDING_TIMEOUT_MS)
            if (currentRunState == RunState.PENDING) {
                android.util.Log.w("GlobalState", "PENDING state timeout, resetting to STOP")
                updateRunState(RunState.STOP)
            }
        }
    }

    fun updateIsStopping(value: Boolean) {
        isStopping = value
        runCatching {
            val ts = if (value) System.currentTimeMillis() else 0L
            BettboxApplication.getAppContext()
                .getSharedPreferences("vpn_state", android.content.Context.MODE_PRIVATE)
                .edit()
                .putLong("stop_lock_ts", ts)
                .apply()
        }
    }

    fun isCurrentlyStopping(): Boolean {
        if (isStopping) return true
        return runCatching {
            val sp = BettboxApplication.getAppContext()
                .getSharedPreferences("vpn_state", android.content.Context.MODE_PRIVATE)
            val ts = sp.getLong("stop_lock_ts", 0L)
            if (ts == 0L) return false

            val now = System.currentTimeMillis()
            if (now - ts > STOP_LOCK_TIMEOUT_MS) {
                sp.edit().remove("stop_lock_ts").apply()
                false
            } else {
                true
            }
        }.getOrDefault(false)
    }

    fun getCurrentAppPlugin(): AppPlugin? {
        val currentEngine = flutterEngine ?: serviceEngine
        return currentEngine?.plugins?.get(AppPlugin::class.java) as? AppPlugin
    }

    fun syncStatus() {
        if (currentRunState == RunState.PENDING) return
        val status = VpnPlugin.getStatus()
        updateRunState(if (status) RunState.START else RunState.STOP)
    }

    suspend fun getText(text: String): String = getCurrentAppPlugin()?.getText(text) ?: ""

    fun getCurrentTilePlugin(): TilePlugin? {
        val currentEngine = flutterEngine ?: serviceEngine
        return currentEngine?.plugins?.get(TilePlugin::class.java) as? TilePlugin
    }

    fun getCurrentVPNPlugin(): VpnPlugin? {
        return serviceEngine?.plugins?.get(VpnPlugin::class.java) as? VpnPlugin
    }

    fun handleToggle() {
        if (!acquireToggleSlot()) return
        when (currentRunState) {
            RunState.START -> handleStop(skipDebounce = true)
            RunState.STOP -> handleStart(skipDebounce = true)
            RunState.PENDING -> Unit
        }
    }

    fun handleStart(skipDebounce: Boolean = false): Boolean {
        if (!skipDebounce && !acquireToggleSlot()) return false
        if (currentRunState != RunState.STOP) return false

        updateRunState(RunState.PENDING)
        startPendingTimeout()
        runLock.withLock {
            getCurrentTilePlugin()?.handleStart() ?: initServiceEngine()
        }
        return true
    }

    fun handleStop(skipDebounce: Boolean = false) {
        if (!skipDebounce && !acquireToggleSlot()) return
        if (currentRunState != RunState.START) return

        updateRunState(RunState.PENDING)
        startPendingTimeout()
        runLock.withLock {
            val tilePlugin = getCurrentTilePlugin()
            if (tilePlugin != null) {
                tilePlugin.handleStop()
            } else {
                VpnPlugin.handleStop(force = true)
            }
        }
    }

    private var restartJob: Job? = null

    @Volatile
    private var isRestartInProgress = false

    fun handleRestart() {
        if (!acquireToggleSlot()) return
        val restartToken = lastToggleAt
        restartJob?.cancel()
        isRestartInProgress = true
        var myJob: Job? = null
        val newJob = scope.launch {
            try {
                handleStop(skipDebounce = true)
                val deadline = SystemClock.elapsedRealtime() + RESTART_WAIT_TIMEOUT_MS
                while (SystemClock.elapsedRealtime() < deadline) {
                    if (lastToggleAt != restartToken) return@launch
                    if (currentRunState == RunState.STOP && !isCurrentlyStopping()) break
                    delay(150L)
                }
                delay(120L)
                if (lastToggleAt != restartToken) return@launch
                if (currentRunState == RunState.STOP) {
                    handleStart(skipDebounce = true)
                    delay(2000L)
                }
            } finally {
                if (restartJob === myJob) {
                    isRestartInProgress = false
                }
            }
        }
        myJob = newJob
        restartJob = newJob
    }

    private fun acquireToggleSlot(): Boolean {
        val now = SystemClock.elapsedRealtime()
        synchronized(this) {
            if (now - lastToggleAt < TOGGLE_DEBOUNCE_MS) return false
            lastToggleAt = now
            return true
        }
    }

    fun handleTryDestroy() {
        if (isRestartInProgress) return
        if (flutterEngine == null) destroyServiceEngine()
    }

    fun destroyServiceEngine() {
        runLock.withLock {
            serviceEngine?.destroy()
            serviceEngine = null
        }
    }

    fun initServiceEngine(flags: List<String>? = null) {
        runLock.withLock {
            if (serviceEngine != null) return
            
            val defaultArgs = if (flutterEngine == null && !isCurrentlyStopping()) listOf("quick") else null
            val args = flags ?: defaultArgs
            
            val app = BettboxApplication.getAppContext() as BettboxApplication
            val vpnService = DartExecutor.DartEntrypoint(
                FlutterInjector.instance().flutterLoader().findAppBundlePath(),
                "_service"
            )
            val options = io.flutter.embedding.engine.FlutterEngineGroup.Options(app).apply {
                dartEntrypoint = vpnService
                dartEntrypointArgs = args
            }
            
            serviceEngine = app.engineGroup.createAndRunEngine(options).apply {
                GeneratedPluginRegistrant.registerWith(this)
                listOf(VpnPlugin, AppPlugin(), TilePlugin(), ServicePlugin()).forEach { plugin ->
                    if (plugins.get(plugin.javaClass) == null) {
                        plugins.add(plugin)
                    }
                }
            }
        }
    }

    fun isServiceEngineRunning(): Boolean = serviceEngine != null

    fun reconnectIpc() {
        (serviceEngine?.plugins?.get(TilePlugin::class.java) as? TilePlugin)?.handleReconnectIpc()
    }
}
