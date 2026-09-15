package com.appshub.bettbox.services

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import com.appshub.bettbox.GlobalState
import com.appshub.bettbox.R
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.security.cert.X509Certificate
import java.util.concurrent.Executors
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSession
import javax.net.ssl.SSLSocketFactory

/**
 * Сторож утечек: живёт, пока поднят VPN (tun), и ловит момент, когда трафик
 * перестаёт выходить через ноду.
 *
 * Идея проверки — один и тот же HTTPS-запрос «какой у меня IP» двумя путями:
 * 1) обычным сокетом: он уходит в tun и выходит через ноду (как весь трафик);
 * 2) сокетом, привязанным к физической сети через network.socketFactory —
 *    мимо tun, с DNS той же физической сети: это реальный IP устройства.
 * Совпали ответы минимум двух эндпоинтов — «через туннель» выходит реальный IP.
 * Туннельный путь молчит, а прямой отвечает — туннель не работает.
 *
 * Эндпоинты: 1.1.1.1/cdn-cgi/trace (IP-литерал — доменные правила конфига
 * на него не влияют), ipinfo.io/json, api.ip.sb/geoip. Утечка засчитывается
 * только при согласии >=2 эндпоинтов и подтверждении вторым раундом, поэтому
 * «прямой маршрут одного сайта по правилам» ложной тревоги не даёт.
 *
 * Триггеры: старт VPN, смена сети, включение экрана, тихий таймер (30 мин,
 * только при включённом экране). Без wakelock'ов: пока экран погашен (doze),
 * раунды не выполняются — батарея не тратится.
 */
class LeakWatchdog(private val context: Context) {
    companion object {
        private const val TAG = "LeakWatchdog"
        private const val CHANNEL_ID = "Bettbox_LeakWatchdog"
        private const val NOTIFICATION_ID = 424001
        private const val PENDING_INTENT_ID = 4241
        private const val MIN_INTERVAL_MS = 45_000L
        private const val STARTUP_DELAY_MS = 10_000L
        private const val NETWORK_DELAY_MS = 4_000L
        private const val SCREEN_DELAY_MS = 6_000L
        private const val CONFIRM_DELAY_MS = 20_000L
        private const val TIMER_INTERVAL_MS = 30L * 60_000L
        private const val TIMEOUT_MS = 8_000

        private const val PROBLEM_NONE = 0
        private const val PROBLEM_LEAK = 1
        private const val PROBLEM_TUNNEL_DOWN = 2

        // JSON («ip»: «x.x.x.x») и plain-текст (ip=x.x.x.x) одним регэкспом.
        private val IP_REGEX =
            Regex("(?:\"ip\"\\s*:\\s*\"|ip=)([0-9a-fA-F:]{2,45}|[0-9.]{7,45})")

        private val ENDPOINTS = listOf(
            Endpoint("1.1.1.1", "/cdn-cgi/trace"),
            Endpoint("ipinfo.io", "/json"),
            Endpoint("api.ip.sb", "/geoip"),
        )
    }

    private data class Endpoint(val host: String, val path: String)

    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private val sslFactory = SSLSocketFactory.getDefault() as SSLSocketFactory

    @Volatile private var started = false
    @Volatile private var stopped = false
    @Volatile private var pendingTask: Runnable? = null
    @Volatile private var screenOn = false
    @Volatile private var currentProblem = PROBLEM_NONE

    private var lastRoundAt = 0L
    private var leakStreak = 0
    private var downStreak = 0

    @Synchronized
    fun start() {
        if (stopped) return
        if (started) {
            // ядро перезапущено: туннель пересоздан — проверим заново
            scheduleRound(STARTUP_DELAY_MS)
            return
        }
        started = true
        lastRoundAt = 0L
        leakStreak = 0
        downStreak = 0
        screenOn =
            (context.getSystemService(Context.POWER_SERVICE) as? PowerManager)?.isInteractive == true
        scheduleRound(STARTUP_DELAY_MS)
        armTimer()
        Log.i(TAG, "watchdog started")
    }

    @Synchronized
    fun stop() {
        if (stopped) return
        stopped = true
        started = false
        pendingTask = null
        mainHandler.removeCallbacksAndMessages(null)
        executor.shutdownNow()
        Log.i(TAG, "watchdog stopped")
    }

    fun onNetworkChanged() {
        if (!started || stopped) return
        scheduleRound(NETWORK_DELAY_MS)
    }

    fun onScreenStateChanged(isOn: Boolean) {
        if (!started || stopped) return
        screenOn = isOn
        if (isOn) scheduleRound(SCREEN_DELAY_MS)
    }

    private fun armTimer() {
        mainHandler.postDelayed({
            if (stopped || !started) return@postDelayed
            if (screenOn) {
                scheduleRound(0L)
            }
            armTimer()
        }, TIMER_INTERVAL_MS)
    }

    private fun scheduleRound(delayMs: Long) {
        if (stopped) return
        pendingTask?.let { mainHandler.removeCallbacks(it) }
        val task = Runnable {
            pendingTask = null
            runRound()
        }
        pendingTask = task
        mainHandler.postDelayed(task, delayMs)
    }

    private fun runRound() {
        if (stopped || !started) return
        val now = System.currentTimeMillis()
        val sinceLast = now - lastRoundAt
        if (sinceLast < MIN_INTERVAL_MS) {
            scheduleRound(MIN_INTERVAL_MS - sinceLast)
            return
        }
        lastRoundAt = now
        executor.execute { doRound() }
    }

    private fun doRound() {
        if (stopped || !started) return
        if (GlobalState.isSmartStopped) return
        val network = physicalNetwork() ?: return
        var realIp: String? = null
        var tunnelOkCount = 0
        var leakAgreements = 0
        for (endpoint in ENDPOINTS) {
            val directIp = fetchIp(endpoint.host, endpoint.path, network)
            if (directIp != null && realIp == null) realIp = directIp
            val tunnelIp = fetchIp(endpoint.host, endpoint.path, null)
            if (tunnelIp != null) tunnelOkCount++
            if (directIp != null && tunnelIp != null && directIp == tunnelIp) leakAgreements++
            if (stopped || !started || GlobalState.isSmartStopped) return
        }
        Log.i(TAG, "round: real=$realIp tunnelOk=$tunnelOkCount agreements=$leakAgreements")
        when {
            realIp == null -> {
                // прямой путь не ответил (каптивный портал, нет интернета) — молчим
            }
            tunnelOkCount == 0 -> {
                leakStreak = 0
                downStreak++
                if (downStreak >= 2) {
                    alertProblem(PROBLEM_TUNNEL_DOWN, realIp, 0)
                } else {
                    scheduleRound(CONFIRM_DELAY_MS)
                }
            }
            leakAgreements >= 2 -> {
                downStreak = 0
                leakStreak++
                if (leakStreak >= 2) {
                    alertProblem(PROBLEM_LEAK, realIp, leakAgreements)
                } else {
                    scheduleRound(CONFIRM_DELAY_MS)
                }
            }
            else -> {
                leakStreak = 0
                downStreak = 0
                clearProblem()
            }
        }
    }

    /// Физическая (не VPN) сеть: её socketFactory даёт сокет мимо tun.
    private fun physicalNetwork(): Network? {
        val cm =
            context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                ?: return null
        return runCatching {
            cm.allNetworks.firstOrNull { network ->
                val caps = cm.getNetworkCapabilities(network) ?: return@firstOrNull false
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                    !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
            }
        }.getOrNull()
    }

    /// IP-литерал резолвить не нужно; домен — через DNS выбранной сети.
    private fun resolveAddress(host: String, network: Network?): InetAddress? {
        return runCatching {
            val literal = host.contains(":") || host.first().isDigit()
            when {
                literal -> InetAddress.getByName(host)
                network != null -> network.getAllByName(host).firstOrNull()
                else -> InetAddress.getAllByName(host).firstOrNull()
            }
        }.getOrNull()
    }

    private fun fetchIp(host: String, path: String, network: Network?): String? {
        return runCatching {
            val address = resolveAddress(host, network) ?: return@runCatching null
            val raw: Socket = if (network != null) {
                network.socketFactory.createSocket()
            } else {
                Socket()
            }
            raw.tcpNoDelay = true
            raw.connect(InetSocketAddress(address, 443), TIMEOUT_MS)
            raw.soTimeout = TIMEOUT_MS
            val ssl = sslFactory.createSocket(raw, host, 443, true) as SSLSocket
            try {
                ssl.startHandshake()
                if (!hostnameMatches(ssl.session, host)) return@runCatching null
                val body = httpGet(ssl, host, path) ?: return@runCatching null
                extractIp(body)
            } finally {
                runCatching { ssl.close() }
            }
        }.onFailure {
            Log.d(TAG, "fetch $host (${if (network == null) "tunnel" else "direct"}) failed: ${it.message}")
        }.getOrNull()
    }

    /// HTTP/1.0 — сервер не станет присылать chunked, тело читается до EOF.
    private fun httpGet(ssl: SSLSocket, host: String, path: String): String? {
        return runCatching {
            val request =
                "GET $path HTTP/1.0\r\nHost: $host\r\nUser-Agent: BettboxR Watchdog\r\n" +
                    "Accept: */*\r\nConnection: close\r\n\r\n"
            ssl.outputStream.write(request.toByteArray(Charsets.UTF_8))
            ssl.outputStream.flush()
            val input = ssl.inputStream
            val buffer = ByteArray(64 * 1024)
            var total = 0
            while (total < buffer.size) {
                val read = input.read(buffer, total, buffer.size - total)
                if (read < 0) break
                total += read
            }
            val text = String(buffer, 0, total, Charsets.UTF_8)
            val separator = text.indexOf("\r\n\r\n")
            if (separator < 0) return@runCatching null
            val head = text.substring(0, separator)
            val status = head.split(" ").getOrNull(1)?.toIntOrNull() ?: return@runCatching null
            if (status < 200 || status >= 300) return@runCatching null
            text.substring(separator + 4).trim()
        }.getOrNull()
    }

    /// Сырой SSLSocket цепочку сертификатов проверяет, но не hostname — сверяем SAN сами.
    private fun hostnameMatches(session: SSLSession, host: String): Boolean {
        return runCatching {
            val cert =
                session.peerCertificates?.firstOrNull() as? X509Certificate
                    ?: return@runCatching false
            val sans = cert.subjectAlternativeNames ?: return@runCatching false
            sans.any { entry ->
                if (entry.size < 2) return@any false
                val type = (entry[0] as? Number)?.toInt()
                val name = (entry[1] as? String) ?: return@any false
                when (type) {
                    2 -> name.equals(host, ignoreCase = true) ||
                        (name.startsWith("*.") && host.endsWith(name.substring(1), ignoreCase = true))
                    7 -> name.equals(host, ignoreCase = true)
                    else -> false
                }
            }
        }.getOrDefault(false)
    }

    private fun extractIp(body: String): String? {
        val value = IP_REGEX.find(body)?.groupValues?.get(1) ?: return null
        val isV4 = value.count { it == '.' } == 3 && value.all { it.isDigit() || it == '.' }
        val isV6 = value.contains(':') &&
            value.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' || it == ':' }
        return if (isV4 || isV6) value else null
    }

    private fun alertProblem(kind: Int, realIp: String?, agreements: Int) {
        if (currentProblem == kind) return
        currentProblem = kind
        postNotification(kind, realIp, agreements)
    }

    private fun clearProblem() {
        currentProblem = PROBLEM_NONE
    }

    private fun postNotification(kind: Int, realIp: String?, agreements: Int) {
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                ?: return
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    "Сторож утечек",
                    NotificationManager.IMPORTANCE_HIGH
                )
                channel.description = "Предупреждения, когда трафик уходит мимо VPN"
                manager.createNotificationChannel(channel)
            }
            val (title, text) = when (kind) {
                PROBLEM_LEAK -> "Обнаружена утечка трафика" to
                    "Запрос через туннель вышел с реального IP $realIp. " +
                    "Нода не используется (эндпоинтов: $agreements)."
                else -> "Туннель не отвечает" to
                    "Нода недоступна, трафик может уходить напрямую с IP $realIp."
            }
            val builder = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic)
                .setContentTitle(title)
                .setContentText(text)
                .setStyle(NotificationCompat.BigTextStyle().bigText(text))
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setCategory(NotificationCompat.CATEGORY_ALARM)
                .setAutoCancel(true)
            val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            if (launchIntent != null) {
                launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                builder.setContentIntent(
                    PendingIntent.getActivity(
                        context,
                        PENDING_INTENT_ID,
                        launchIntent,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                    )
                )
            }
            manager.notify(NOTIFICATION_ID, builder.build())
        }.onFailure {
            Log.e(TAG, "notify failed: ${it.message}")
        }
    }
}
