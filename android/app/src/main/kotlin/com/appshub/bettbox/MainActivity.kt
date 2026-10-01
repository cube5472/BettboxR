package com.appshub.bettbox

import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Base64
import android.util.Log
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import com.appshub.bettbox.plugins.AppPlugin
import com.appshub.bettbox.plugins.ServicePlugin
import com.appshub.bettbox.plugins.TilePlugin
import com.appshub.bettbox.plugins.VpnPlugin
import com.appshub.bettbox.services.BettboxVpnService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineGroup
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import java.io.BufferedInputStream
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URI
import java.util.zip.GZIPInputStream
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket

class MainActivity : FlutterActivity() {
    companion object {
        private const val MAIN_ENGINE_ID = "bettbox_main_engine"
    }

    private fun isTvDevice(context: Context): Boolean {
        val uiModeManager = context.getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
        if (uiModeManager?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION) {
            return true
        }
        val packageManager = context.packageManager
        return packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
                || packageManager.hasSystemFeature(PackageManager.FEATURE_TELEVISION)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        val isEngineCached = FlutterEngineCache.getInstance().contains(MAIN_ENGINE_ID)
        if (isTvDevice(this) || isEngineCached) {
            setTheme(R.style.NormalTheme)
        } else {
            installSplashScreen()
        }
        super.onCreate(savedInstanceState)
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine {
        val engineCache = FlutterEngineCache.getInstance()
        return engineCache.get(MAIN_ENGINE_ID) ?: createAndCacheEngine(context, engineCache)
    }

    private fun createAndCacheEngine(context: Context, cache: FlutterEngineCache): FlutterEngine {
        val app = context.applicationContext as BettboxApplication
        val options = FlutterEngineGroup.Options(app).apply {
            dartEntrypoint = DartExecutor.DartEntrypoint.createDefault()
        }
        return app.engineGroup.createAndRunEngine(options).apply {
            GeneratedPluginRegistrant.registerWith(this)
            cache.put(MAIN_ENGINE_ID, this)
            GlobalState.flutterEngine = this
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        listOf(VpnPlugin, AppPlugin(), ServicePlugin(), TilePlugin()).forEach { plugin ->
            if (flutterEngine.plugins.get(plugin.javaClass) == null) {
                flutterEngine.plugins.add(plugin)
            }
        }

        setupHapticsChannel(flutterEngine)

        setupDeviceChannel(flutterEngine)

        GlobalState.flutterEngine = flutterEngine
    }

    private fun setupHapticsChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "code_forge/haptics")
            .setMethodCallHandler { call, result ->
                val decorView = window?.decorView
                if (decorView == null) {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "handleMove" -> {
                        decorView.performHapticFeedback(
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                HapticFeedbackConstants.TEXT_HANDLE_MOVE
                            } else {
                                HapticFeedbackConstants.LONG_PRESS
                            }
                        )
                        result.success(null)
                    }
                    "longPress" -> {
                        decorView.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // android_id для стабильного X-Hwid (lib/models/sub_spoof.dart):
    // Settings.Secure.ANDROID_ID индивидуален для подписи приложения.
    // Ошибки глушим null-ом — подмена не должна ломать работу.
    private fun setupDeviceChannel(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "code_forge/device"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getAndroidId" -> {
                    try {
                        result.success(
                            Settings.Secure.getString(
                                contentResolver,
                                Settings.Secure.ANDROID_ID
                            )
                        )
                    } catch (e: Exception) {
                        result.success(null)
                    }
                }
                "protectedFetch" -> handleProtectedFetch(
                    call.arguments as? Map<*, *>,
                    result
                )
                else -> result.notImplemented()
            }
        }
    }

    // ---- Прямой защищённый фетч подписок (резервный путь) ----
    //
    // Обычное скачивание подписок идёт через ядро (mixed-port): DNS
    // профиля, маршруты, зависимость от здоровья туннеля. Резервный
    // путь качает URL напрямую из процесса приложения: сокет выводится
    // из-под собственного TUN через VpnService.protect ДО connect,
    // DNS системный — запрос неотличим от запроса обычного приложения
    // без VPN. Редиректы обрабатываются вручную с сохранением всех
    // заголовков (у HttpURLConnection переносы заголовков при редиректе
    // не гарантированы). HTTP-разбор ручной — не зависит от деталей
    // сетевого стека платформы.

    private fun handleProtectedFetch(
        args: Map<*, *>?,
        result: MethodChannel.Result
    ) {
        val url = (args?.get("url") as? String).orEmpty()
        val headers = (args?.get("headers") as? Map<*, *>)
            ?.mapKeys { it.key.toString() }
            ?.mapValues { it.value.toString() }
            ?: emptyMap()
        Thread {
            val outcome = runCatching { protectedFetchHttp(url, headers) }
                .getOrElse {
                    mapOf(
                        "error" to "${it.javaClass.simpleName}: " +
                            (it.message ?: "fetch failed")
                    )
                }
            runOnUiThread {
                runCatching { result.success(outcome) }
            }
        }.start()
    }

    private fun protectSocket(socket: Socket) {
        // ВАЖНО: protect() — метод ЭКЗЕМПЛЯРА VpnService (статического
        // не существует, компиляция через VpnService.protect валится
        // с "Unresolved reference 'protect'"). Берём живой BettboxVpnService;
        // пока VPN выключен, экземпляра нет и сокет без того идёт
        // напрямую — защита не нужна. protect(Socket) обязан вызываться
        // ДО connect — вызов стоит сразу после создания сокета.
        runCatching { BettboxVpnService.current?.protect(socket) }
    }

    private fun readCrLfLine(input: BufferedInputStream): String {
        val sb = StringBuilder()
        while (true) {
            val b = input.read()
            if (b == -1 || b == 10) break
            if (b != 13) sb.append(b.toChar())
        }
        return sb.toString()
    }

    private fun readBody(
        input: BufferedInputStream,
        headers: Map<String, String>
    ): ByteArray {
        val encoding = (headers["transfer-encoding"] ?: "").lowercase()
        if (encoding.contains("chunked")) {
            val out = ByteArrayOutputStream()
            while (true) {
                val sizeLine = readCrLfLine(input)
                val size = sizeLine.trim().substringBefore(';').toIntOrNull(16) ?: 0
                if (size == 0) {
                    while (true) {
                        if (readCrLfLine(input).isEmpty()) break
                    }
                    break
                }
                val chunk = ByteArray(size)
                var read = 0
                while (read < size) {
                    val n = input.read(chunk, read, size - read)
                    if (n == -1) break
                    read += n
                }
                out.write(chunk, 0, read)
                readCrLfLine(input)
            }
            return out.toByteArray()
        }
        val length = headers["content-length"]?.trim()?.toIntOrNull()
        if (length != null && length >= 0) {
            val body = ByteArray(length)
            var read = 0
            while (read < length) {
                val n = input.read(body, read, length - read)
                if (n == -1) break
                read += n
            }
            return if (read == length) body else body.copyOf(read)
        }
        return input.readBytes()
    }

    private fun protectedFetchHttp(
        url: String,
        headers: Map<String, String>
    ): Map<String, Any> {
        var current = url
        repeat(5) {
            val uri = URI(current)
            val scheme = uri.scheme ?: "https"
            val port = when {
                uri.port > 0 -> uri.port
                scheme == "https" -> 443
                else -> 80
            }
            val host = uri.host
                ?: throw IllegalArgumentException("bad url: $current")
            val path = buildString {
                append(uri.rawPath ?: "/")
                if (!uri.rawQuery.isNullOrEmpty()) {
                    append('?')
                    append(uri.rawQuery)
                }
            }
            val plain = Socket()
            protectSocket(plain)
            plain.connect(InetSocketAddress(host, port), 20000)
            plain.soTimeout = 30000
            val sock: Socket = if (scheme == "https") {
                val factory = SSLContext.getDefault().socketFactory
                val ssl = factory.createSocket(plain, host, port, true) as SSLSocket
                ssl.startHandshake()
                ssl
            } else {
                plain
            }
            try {
                val request = StringBuilder()
                request.append("GET ").append(path).append(" HTTP/1.1\r\n")
                request.append("Host: ").append(host).append("\r\n")
                request.append("Connection: close\r\n")
                headers.forEach { (name, value) ->
                    if (!name.equals("host", true) &&
                        !name.equals("connection", true)
                    ) {
                        request.append(name).append(": ").append(value).append("\r\n")
                    }
                }
                if (headers.keys.none { it.equals("accept-encoding", true) }) {
                    request.append("Accept-Encoding: gzip\r\n")
                }
                request.append("\r\n")
                sock.getOutputStream().write(
                    request.toString().toByteArray(Charsets.ISO_8859_1)
                )
                sock.getOutputStream().flush()

                val input = BufferedInputStream(sock.getInputStream())
                val statusLine = readCrLfLine(input)
                val code = statusLine.split(" ").getOrNull(1)?.toIntOrNull() ?: 0
                val responseHeaders = LinkedHashMap<String, String>()
                while (true) {
                    val line = readCrLfLine(input)
                    if (line.isEmpty()) break
                    val idx = line.indexOf(':')
                    if (idx > 0) {
                        responseHeaders[line.substring(0, idx).trim().lowercase()] =
                            line.substring(idx + 1).trim()
                    }
                }
                val location = responseHeaders["location"]
                if (code in 300..399 && !location.isNullOrEmpty()) {
                    sock.close()
                    current = URI(current).resolve(location).toString()
                    return@repeat
                }
                var body = readBody(input, responseHeaders)
                val contentEncoding = responseHeaders["content-encoding"] ?: ""
                if (contentEncoding.lowercase().contains("gzip")) {
                    body = GZIPInputStream(ByteArrayInputStream(body)).readBytes()
                }
                sock.close()
                return mapOf(
                    "status" to code,
                    "headers" to responseHeaders,
                    "body" to Base64.encodeToString(body, Base64.NO_WRAP)
                )
            } finally {
                runCatching { sock.close() }
                runCatching { plain.close() }
            }
        }
        return mapOf("error" to "too many redirects")
    }

    override fun shouldDestroyEngineWithHost(): Boolean = false

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        val engine = flutterEngine
        if (engine != null) {
            engine.navigationChannel.popRoute()
        } else {
            super.onBackPressed()
        }
    }

    override fun dispatchTouchEvent(ev: MotionEvent?): Boolean {
        return try {
            super.dispatchTouchEvent(ev)
        } catch (e: RuntimeException) {
            if (e.message?.contains("FlutterJNI is not attached to native") == true) {
                Log.w("MainActivity", "Ignore touch event while FlutterJNI is not attached")
                false
            } else {
                throw e
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
    }
}
