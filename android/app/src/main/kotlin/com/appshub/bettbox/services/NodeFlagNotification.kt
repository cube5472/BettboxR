package com.appshub.bettbox.services

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Typeface

/**
 * Второе тихое уведомление: страна выбранной ноды рядом с иконкой
 * приложения («кубиком») в статус-баре.
 *
 * ВАЖНО О ОГРАНИЧЕНИИ ANDROID: smallIcon в статус-баре всегда рендерится
 * как монохромная альфа-маска — цвета bitmap-иконки система выбрасывает.
 * Поэтому цветной флаг в статус-баре показать невозможно в принципе
 * (цветной bitmap даёт белый силуэт-прямоугольник — выглядит как мусор).
 * Компромисс:
 *  - статус-бар: белый силуэт ISO-кода страны («SE», «DE»), для
 *    неопределённой страны — силуэт «флажка на древке»;
 *  - шторка: цветной флаг страны как largeIcon + флаг-эмодзи в тексте
 *    («Bettbox • 🇩🇪 DE») — эмодзи и largeIcon рендерятся в цвете.
 *
 * Публичные точки входа — [update] (пустой код страны И пустое имя ноды
 * убирают уведомление; если нода есть, а страна не определена — постится
 * нейтральный «флажок», пока IP-проверка не уточнит страну) и [restore]
 * (восстановление при старте сервиса, когда приложение не открыто).
 * Сервис при остановке вызывает [cancel].
 * Внешний гейт «VPN запущен» — в VpnPlugin.handleUpdateNotificationFlag.
 */
object NodeFlagNotification {
    const val ID = 30001
    private const val CHANNEL_ID = "Bettbox_NodeFlag"
    private const val PREFS = "bettbox_node_flag"
    private const val KEY_CODE = "countryCode"
    private const val KEY_NODE = "nodeName"

    @Volatile
    private var lastKey: String? = null

    fun update(context: Context?, countryCode: String?, nodeName: String?) {
        if (context == null) return
        val manager =
            context.getSystemService(NotificationManager::class.java) ?: return

        val code = countryCode?.trim()
            ?.uppercase()
            ?.takeIf { it.length == 2 && it.all { ch -> ch in 'A'..'Z' } }
        val name = nodeName?.trim()?.takeIf { it.isNotEmpty() }

        if (code == null) {
            // Страна не определена. Совсем без ноды флаг ни к чему —
            // снимаем уведомление. А при ноде с «безликим» именем (личный
            // VPS и т.п.) показываем нейтральный «флажок»: уведомление
            // с флагом живёт всегда, а после IP-проверки Dart пришлёт
            // реальный код страны.
            if (name == null) {
                cancel(context)
                return
            }
            savePrefs(context, "", name)
            val key = "?|$name"
            if (key == lastKey) return
            lastKey = key
            post(context, manager, null, name)
            return
        }

        savePrefs(context, code, name)

        val key = "$code|$name"
        if (key == lastKey) return
        lastKey = key

        post(context, manager, code, name)
    }

    /**
     * Восстановление флага при старте сервиса: рестарт процесса,
     * Always-on VPN после загрузки, свайп приложения из recents —
     * когда Dart-код ещё не запускался и постить флаг некому.
     * Читает последнюю сохранённую пару (код страны, имя ноды) из
     * SharedPreferences и постит уведомление заново. Пустой код страны
     * (неопределённая страна) восстанавливается нейтральным «флажком».
     */
    fun restore(context: Context?) {
        if (context == null) return
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val code = prefs.getString(KEY_CODE, null)?.trim()
            ?.uppercase()
            ?.takeIf { it.length == 2 && it.all { ch -> ch in 'A'..'Z' } }
        val nodeName = prefs.getString(KEY_NODE, null)?.trim()?.takeIf { it.isNotEmpty() }
        if (code == null && nodeName == null) return
        val manager =
            context.getSystemService(NotificationManager::class.java) ?: return
        lastKey = "${code ?: "?"}|$nodeName"
        post(context, manager, code, nodeName)
    }

    private fun post(
        context: Context,
        manager: NotificationManager,
        code: String?,
        nodeName: String?,
    ) {
        runCatching {
            ensureChannel(context, manager)
            // Статус-бар: монохромный силуэт ISO-кода («SE») или «флажок»;
            // шторка: цветной флаг (largeIcon) + эмодзи в тексте.
            val title = nodeName?.trim()?.takeIf { it.isNotEmpty() } ?: "Bettbox"
            val text = if (code != null) "Bettbox • ${flagEmoji(code)} $code" else "Bettbox"
            val notification = Notification.Builder(context, CHANNEL_ID)
                .setSmallIcon(
                    android.graphics.drawable.Icon.createWithBitmap(
                        FlagPainter.paintSmall(code)
                    )
                )
                .setLargeIcon(
                    android.graphics.drawable.Icon.createWithBitmap(
                        FlagPainter.paintLarge(code)
                    )
                )
                .setContentTitle(title)
                .setContentText(text)
                .setOngoing(true)
                .setShowWhen(false)
                .setPriority(Notification.PRIORITY_LOW)
                .setCategory(Notification.CATEGORY_SERVICE)
                .build()
            manager.notify(ID, notification)
        }.onFailure {
            android.util.Log.e("NodeFlagNotification", "update error: ${it.message}")
        }
    }

    /** Флаг-эмодзи из ISO-кода («DE» → «🇩🇪») для цветного отображения в шторке. */
    private fun flagEmoji(code: String): String {
        val upper = code.trim().uppercase()
        if (upper.length != 2 || !upper.all { it in 'A'..'Z' }) return ""
        val sb = StringBuilder()
        for (ch in upper) {
            sb.append(String(Character.toChars(0x1F1E6 + (ch - 'A'))))
        }
        return sb.toString()
    }

    private fun savePrefs(context: Context, code: String, nodeName: String?) {
        runCatching {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_CODE, code)
                .putString(KEY_NODE, nodeName?.trim()?.takeIf { it.isNotEmpty() } ?: "")
                .apply()
        }
    }

    fun cancel(context: Context?) {
        if (context == null) return
        lastKey = null
        runCatching {
            context.getSystemService(NotificationManager::class.java)?.cancel(ID)
        }
    }

    private fun ensureChannel(context: Context, manager: NotificationManager) {
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Bettbox Node Flag",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            setShowBadge(false)
            setSound(null, null)
            enableVibration(false)
        }
        manager.createNotificationChannel(channel)
    }
}

/**
 * Программный рисовальщик упрощённых флагов стран в bitmap 48x48
 * (полотно флага 48x32 по центру, прозрачные поля сверху/снизу — так
 * статус-бар не обрезает флаг 3:2 квадратной рамкой иконки).
 *
 * Дизайны упрощённые, но узнаваемые: полосы (с весами), кресты,
 * круги и особые случаи (США, Великобритания, Бразилия и т.д.).
 * Неизвестный код — нейтральная иконка «флажок».
 */
object FlagPainter {
    private const val SIZE = 48
    private const val FW = 48f
    private const val FH = 32f
    private const val TOP = 8f

    private const val kindH = "H"
    private const val kindV = "V"
    private const val kindCross = "CROSS"
    private const val kindCircle = "CIRCLE"
    private const val kindSpecial = "SPECIAL"

    /** kind — тип дизайна; colors — палитра; weights — веса полос. */
    private class Design(val kind: String, val colors: IntArray, val weights: FloatArray)

    private fun d(kind: String, weights: FloatArray, vararg colors: Long) =
        Design(kind, colors.map { it.toInt() }.toIntArray(), weights)

    private val flags: Map<String, Design> = mapOf(
        // — горизонтальные полосы —
        "DE" to d(kindH, floatArrayOf(1f, 1f, 1f), 0xFF000000, 0xFFDD0000, 0xFFFFCE00),
        "RU" to d(kindH, floatArrayOf(1f, 1f, 1f), 0xFFFFFFFF, 0xFF0039A6, 0xFFD52B1E),
        "NL" to d(kindH, floatArrayOf(1f, 1f, 1f), 0xFFAE1C28, 0xFFFFFFFF, 0xFF21468B),
        "AT" to d(kindH, floatArrayOf(1f, 1f, 1f), 0xFFED2939, 0xFFFFFFFF, 0xFFED2939),
        "HU" to d(kindH, floatArrayOf(1f, 1f, 1f), 0xFFCE2939, 0xFFFFFFFF, 0xFF477050),
        "BG" to d(kindH, floatArrayOf(1f, 1f, 1f), 0xFFFFFFFF, 0xFF00966E, 0xFFD62612),
        "EE" to d(kindH, floatArrayOf(1f, 1f, 1f), 0xFF0072CE, 0xFF000000, 0xFFFFFFFF),
        "LT" to d(kindH, floatArrayOf(1f, 1f, 1f), 0xFFFDB913, 0xFF006A44, 0xFFC1272D),
        "AM" to d(kindH, floatArrayOf(1f, 1f, 1f), 0xFFD90012, 0xFF0033A0, 0xFFF2A800),
        "RS" to d(kindH, floatArrayOf(1f, 1f, 1f), 0xFFC6363C, 0xFF0C4076, 0xFFFFFFFF),
        "SI" to d(kindH, floatArrayOf(1f, 1f, 1f), 0xFFFFFFFF, 0xFF005DA4, 0xFFED1C24),
        "HR" to d(kindH, floatArrayOf(1f, 1f, 1f), 0xFFFF0000, 0xFFFFFFFF, 0xFF171796),
        "SK" to d(kindH, floatArrayOf(1f, 1f, 1f), 0xFFFFFFFF, 0xFF0B4EA2, 0xFFEE1C25),
        "UZ" to d(kindH, floatArrayOf(1f, 1f, 1f), 0xFF0099B5, 0xFFFFFFFF, 0xFF1EB53A),
        "EG" to d(kindH, floatArrayOf(1f, 1f, 1f), 0xFFCE1126, 0xFFFFFFFF, 0xFF000000),
        "LU" to d(kindH, floatArrayOf(1f, 1f, 1f), 0xFFEF3340, 0xFFFFFFFF, 0xFF00A2E1),
        // — горизонтальные полосы с весами / две полосы —
        "UA" to d(kindH, floatArrayOf(1f, 1f), 0xFF0057B7, 0xFFFFD700),
        "PL" to d(kindH, floatArrayOf(1f, 1f), 0xFFFFFFFF, 0xFFDC143C),
        "ID" to d(kindH, floatArrayOf(1f, 1f), 0xFFCE1126, 0xFFFFFFFF),
        "ES" to d(kindH, floatArrayOf(1f, 2f, 1f), 0xFFAA151B, 0xFFF1BF00, 0xFFAA151B),
        "TH" to d(kindH, floatArrayOf(1f, 1f, 2f, 1f, 1f), 0xFFA51931, 0xFFF2F2F2, 0xFF2D2A4A, 0xFFF2F2F2, 0xFFA51931),
        // — вертикальные полосы —
        "FR" to d(kindV, floatArrayOf(1f, 1f, 1f), 0xFF0055A4, 0xFFFFFFFF, 0xFFEF4135),
        "IT" to d(kindV, floatArrayOf(1f, 1f, 1f), 0xFF009246, 0xFFFFFFFF, 0xFFCE2B37),
        "BE" to d(kindV, floatArrayOf(1f, 1f, 1f), 0xFF000000, 0xFFFDDA24, 0xFFEF3340),
        "IE" to d(kindV, floatArrayOf(1f, 1f, 1f), 0xFF169B62, 0xFFFFFFFF, 0xFFFF883E),
        "RO" to d(kindV, floatArrayOf(1f, 1f, 1f), 0xFF002B7F, 0xFFFCD116, 0xFFCE1126),
        "MD" to d(kindV, floatArrayOf(1f, 1f, 1f), 0xFF0046AE, 0xFFFFD200, 0xFFCC092F),
        "MX" to d(kindV, floatArrayOf(1f, 1f, 1f), 0xFF006847, 0xFFFFFFFF, 0xFFCE1126),
        "PE" to d(kindV, floatArrayOf(1f, 1f, 1f), 0xFFD91023, 0xFFFFFFFF, 0xFFD91023),
        "CA" to d(kindV, floatArrayOf(1f, 2f, 1f), 0xFFFF0000, 0xFFFFFFFF, 0xFFFF0000),
        "PT" to d(kindV, floatArrayOf(2f, 3f), 0xFF046A38, 0xFFDA291C),
        // — кресты: colors = фон, крест, наложение; weights[0] == 0 — крест в центре —
        "SE" to d(kindCross, floatArrayOf(1f, 1f, 1f), 0xFF006AA7, 0xFFFECC02, 0xFFFECC02),
        "FI" to d(kindCross, floatArrayOf(1f, 1f, 1f), 0xFFFFFFFF, 0xFF003580, 0xFF003580),
        "DK" to d(kindCross, floatArrayOf(1f, 1f, 1f), 0xFFC8102E, 0xFFFFFFFF, 0xFFFFFFFF),
        "NO" to d(kindCross, floatArrayOf(1f, 1f, 1f), 0xFFBA0C2F, 0xFFFFFFFF, 0xFF00205B),
        "IS" to d(kindCross, floatArrayOf(1f, 1f, 1f), 0xFF02529C, 0xFFFFFFFF, 0xFFDC1E35),
        "GE" to d(kindCross, floatArrayOf(0f, 1f, 1f), 0xFFFFFFFF, 0xFFFF0000, 0xFFFF0000),
        "CH" to d(kindCross, floatArrayOf(0f, 1f, 1f), 0xFFDA291C, 0xFFFFFFFF, 0xFFFFFFFF),
        // — круги: colors = фон, круг, (дубль круга) —
        "JP" to d(kindCircle, floatArrayOf(1f, 1f, 1f), 0xFFFFFFFF, 0xFFBC002D, 0xFFBC002D),
        "BD" to d(kindCircle, floatArrayOf(1f, 1f, 1f), 0xFF006A4E, 0xFFF42A41, 0xFFF42A41),
        "KZ" to d(kindCircle, floatArrayOf(1f, 1f, 1f), 0xFF00AFCA, 0xFFFEC50C, 0xFFFEC50C),
        "IN" to d(kindCircle, floatArrayOf(1f, 1f, 1f), 0xFFFFFFFF, 0xFF000080, 0xFF000080),
        "AR" to d(kindCircle, floatArrayOf(1f, 1f, 1f), 0xFF74ACDF, 0xFFF6B40E, 0xFFF6B40E),
        // — особые случаи —
        "US" to d(kindSpecial, floatArrayOf(1f, 1f, 1f), 0xFFB22234, 0xFFFFFFFF, 0xFF3C3B6E),
        "GB" to d(kindSpecial, floatArrayOf(1f, 1f, 1f), 0xFF012169, 0xFFFFFFFF, 0xFFC8102E),
        "CZ" to d(kindSpecial, floatArrayOf(1f, 1f, 1f), 0xFFFFFFFF, 0xFFD7141A, 0xFF11457E),
        "GR" to d(kindSpecial, floatArrayOf(1f, 1f, 1f), 0xFF0D5EAF, 0xFFFFFFFF, 0xFF0D5EAF),
        "TR" to d(kindSpecial, floatArrayOf(1f, 1f, 1f), 0xFFE30A17, 0xFFFFFFFF, 0xFFE30A17),
        "CN" to d(kindSpecial, floatArrayOf(1f, 1f, 1f), 0xFFDE2910, 0xFFFFDE00, 0xFFFFDE00),
        "VN" to d(kindSpecial, floatArrayOf(1f, 1f, 1f), 0xFFDA251D, 0xFFFFDE00, 0xFFFFDE00),
        "KR" to d(kindSpecial, floatArrayOf(1f, 1f, 1f), 0xFFFFFFFF, 0xFFCD2E3A, 0xFF0047A0),
        "IL" to d(kindSpecial, floatArrayOf(1f, 1f, 1f), 0xFFFFFFFF, 0xFF0038B8, 0xFF0038B8),
        "SG" to d(kindSpecial, floatArrayOf(1f, 1f, 1f), 0xFFEF3340, 0xFFFFFFFF, 0xFFFFFFFF),
        "TW" to d(kindSpecial, floatArrayOf(1f, 1f, 1f), 0xFFFE0000, 0xFF000095, 0xFFFFFFFF),
        "MY" to d(kindSpecial, floatArrayOf(1f, 1f, 1f), 0xFFCC0001, 0xFFFFFFFF, 0xFF010066),
        "BR" to d(kindSpecial, floatArrayOf(1f, 1f, 1f), 0xFF009C3B, 0xFFFFDF00, 0xFF002776),
        "CL" to d(kindSpecial, floatArrayOf(1f, 1f, 1f), 0xFFD52B1E, 0xFFFFFFFF, 0xFF0039A6),
        "AE" to d(kindSpecial, floatArrayOf(1f, 1f, 1f), 0xFF00732F, 0xFFFFFFFF, 0xFF000000),
        "BY" to d(kindSpecial, floatArrayOf(1f, 1f, 1f), 0xFFCE1720, 0xFF007C30, 0xFFFFFFFF),
        "AU" to d(kindSpecial, floatArrayOf(1f, 1f, 1f), 0xFF00247D, 0xFFFFFFFF, 0xFFFFFFFF),
        "NZ" to d(kindSpecial, floatArrayOf(1f, 1f, 1f), 0xFF00247D, 0xFFCC142B, 0xFFFFFFFF),
    )

    fun paint(code: String): Bitmap {
        val bitmap = Bitmap.createBitmap(SIZE, SIZE, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val design = flags[code.uppercase()]
        if (design == null) {
            paintGeneric(canvas)
            return bitmap
        }
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        when (design.kind) {
            kindH -> {
                val total = design.weights.sum()
                var y = TOP
                for (i in design.colors.indices) {
                    val h = FH * (design.weights[i] / total)
                    paint.color = design.colors[i]
                    canvas.drawRect(0f, y, FW, y + h, paint)
                    y += h
                }
            }
            kindV -> {
                val total = design.weights.sum()
                var x = 0f
                for (i in design.colors.indices) {
                    val w = FW * (design.weights[i] / total)
                    paint.color = design.colors[i]
                    canvas.drawRect(x, TOP, x + w, TOP + FH, paint)
                    x += w
                }
            }
            kindCross -> {
                // colors[0] — фон, colors[1] — крест, colors[2] — наложение
                // (для NO/IS); weights[0] == 0 — крест в центре (CH, GE).
                paint.color = design.colors[0]
                canvas.drawRect(0f, TOP, FW, TOP + FH, paint)
                val centered = design.weights[0] == 0f
                val cw = FH * 0.2f
                val cx = if (centered) FW / 2f else FW * 0.36f
                paint.color = design.colors[1]
                canvas.drawRect(cx - cw / 2f, TOP, cx + cw / 2f, TOP + FH, paint)
                canvas.drawRect(0f, TOP + FH / 2f - cw / 2f, FW, TOP + FH / 2f + cw / 2f, paint)
                if (design.colors[2] != design.colors[1]) {
                    val cw2 = cw * 0.55f
                    paint.color = design.colors[2]
                    canvas.drawRect(cx - cw2 / 2f, TOP, cx + cw2 / 2f, TOP + FH, paint)
                    canvas.drawRect(0f, TOP + FH / 2f - cw2 / 2f, FW, TOP + FH / 2f + cw2 / 2f, paint)
                }
            }
            kindCircle -> {
                paint.color = design.colors[0]
                canvas.drawRect(0f, TOP, FW, TOP + FH, paint)
                paint.color = design.colors[1]
                canvas.drawCircle(FW / 2f, TOP + FH / 2f, FH * 0.3f, paint)
            }
            kindSpecial -> paintSpecial(canvas, code.uppercase(), design.colors, paint)
        }
        return bitmap
    }

    private fun paintSpecial(canvas: Canvas, code: String, colors: IntArray, paint: Paint) {
        when (code) {
            "US" -> {
                // 13 красно-белых полос + синий кантон.
                val stripeH = FH / 13f
                var y = TOP
                for (i in 0 until 13) {
                    paint.color = if (i % 2 == 0) colors[0] else colors[1]
                    canvas.drawRect(0f, y, FW, y + stripeH, paint)
                    y += stripeH
                }
                paint.color = colors[2]
                canvas.drawRect(0f, TOP, FW * 0.42f, TOP + stripeH * 7f, paint)
            }
            "GB" -> drawUnionJack(canvas, 0f, TOP, FW, FH, paint)
            "CZ" -> {
                paint.color = colors[0]
                canvas.drawRect(0f, TOP, FW, TOP + FH / 2f, paint)
                paint.color = colors[1]
                canvas.drawRect(0f, TOP + FH / 2f, FW, TOP + FH, paint)
                paint.color = colors[2]
                val path = Path()
                path.moveTo(0f, TOP)
                path.lineTo(FW * 0.45f, TOP + FH / 2f)
                path.lineTo(0f, TOP + FH)
                path.close()
                canvas.drawPath(path, paint)
            }
            "GR" -> {
                val stripeH = FH / 9f
                var y = TOP
                for (i in 0 until 9) {
                    paint.color = if (i % 2 == 0) colors[0] else colors[1]
                    canvas.drawRect(0f, y, FW, y + stripeH, paint)
                    y += stripeH
                }
                paint.color = colors[0]
                canvas.drawRect(0f, TOP, FW * 0.37f, TOP + stripeH * 5f, paint)
                paint.color = colors[1]
                val cw = stripeH * 0.6f
                canvas.drawRect(FW * 0.185f - cw / 2f, TOP, FW * 0.185f + cw / 2f, TOP + stripeH * 5f, paint)
                canvas.drawRect(0f, TOP + stripeH * 2.5f - cw / 2f, FW * 0.37f, TOP + stripeH * 2.5f + cw / 2f, paint)
            }
            "TR" -> {
                paint.color = colors[0]
                canvas.drawRect(0f, TOP, FW, TOP + FH, paint)
                paint.color = colors[1]
                canvas.drawCircle(FW * 0.36f, TOP + FH / 2f, FH * 0.25f, paint)
                paint.color = colors[0]
                canvas.drawCircle(FW * 0.42f, TOP + FH / 2f, FH * 0.2f, paint)
                paint.color = colors[1]
                canvas.drawPath(starPath(FW * 0.62f, TOP + FH / 2f, FH * 0.12f), paint)
            }
            "CN", "VN" -> {
                paint.color = colors[0]
                canvas.drawRect(0f, TOP, FW, TOP + FH, paint)
                paint.color = colors[1]
                if (code == "CN") {
                    canvas.drawPath(starPath(FW * 0.2f, TOP + FH * 0.3f, FH * 0.18f), paint)
                } else {
                    canvas.drawPath(starPath(FW / 2f, TOP + FH / 2f, FH * 0.28f), paint)
                }
            }
            "KR" -> {
                paint.color = colors[0]
                canvas.drawRect(0f, TOP, FW, TOP + FH, paint)
                val cx = FW / 2f
                val cy = TOP + FH / 2f
                val r = FH * 0.28f
                // Тхэгык: верхняя половина красная, нижняя синяя.
                paint.color = colors[1]
                canvas.drawArc(RectF(cx - r, cy - r, cx + r, cy + r), 180f, 180f, true, paint)
                paint.color = colors[2]
                canvas.drawArc(RectF(cx - r, cy - r, cx + r, cy + r), 0f, 180f, true, paint)
            }
            "IL" -> {
                paint.color = colors[0]
                canvas.drawRect(0f, TOP, FW, TOP + FH, paint)
                paint.color = colors[1]
                canvas.drawRect(0f, TOP + FH * 0.12f, FW, TOP + FH * 0.26f, paint)
                canvas.drawRect(0f, TOP + FH * 0.74f, FW, TOP + FH * 0.88f, paint)
                // Звезда Давида — два контурных треугольника.
                paint.style = Paint.Style.STROKE
                paint.strokeWidth = FH * 0.06f
                val cy = TOP + FH / 2f
                val r = FH * 0.2f
                canvas.drawPath(trianglePath(FW / 2f, cy - r * 0.5f, r, true), paint)
                canvas.drawPath(trianglePath(FW / 2f, cy + r * 0.5f, r, false), paint)
                paint.style = Paint.Style.FILL
            }
            "SG" -> {
                paint.color = colors[0]
                canvas.drawRect(0f, TOP, FW, TOP + FH / 2f, paint)
                paint.color = colors[1]
                canvas.drawRect(0f, TOP + FH / 2f, FW, TOP + FH, paint)
                // Полумесяц: белый круг + красный сдвиг; рядом «звёзды».
                canvas.drawCircle(FW * 0.24f, TOP + FH * 0.25f, FH * 0.16f, paint)
                paint.color = colors[0]
                canvas.drawCircle(FW * 0.3f, TOP + FH * 0.25f, FH * 0.14f, paint)
                paint.color = colors[1]
                canvas.drawCircle(FW * 0.44f, TOP + FH * 0.18f, FH * 0.04f, paint)
                canvas.drawCircle(FW * 0.52f, TOP + FH * 0.25f, FH * 0.04f, paint)
                canvas.drawCircle(FW * 0.44f, TOP + FH * 0.32f, FH * 0.04f, paint)
            }
            "TW" -> {
                paint.color = colors[0]
                canvas.drawRect(0f, TOP, FW, TOP + FH, paint)
                paint.color = colors[1]
                canvas.drawRect(0f, TOP, FW * 0.5f, TOP + FH / 2f, paint)
                paint.color = colors[2]
                canvas.drawCircle(FW * 0.25f, TOP + FH * 0.25f, FH * 0.15f, paint)
            }
            "MY" -> {
                val stripeH = FH / 14f
                var y = TOP
                for (i in 0 until 14) {
                    paint.color = if (i % 2 == 0) colors[0] else colors[1]
                    canvas.drawRect(0f, y, FW, y + stripeH, paint)
                    y += stripeH
                }
                paint.color = colors[2]
                canvas.drawRect(0f, TOP, FW * 0.5f, TOP + stripeH * 7f, paint)
                paint.color = 0xFFFFCC00.toInt()
                canvas.drawCircle(FW * 0.22f, TOP + stripeH * 3.5f, stripeH * 1.6f, paint)
                paint.color = colors[2]
                canvas.drawCircle(FW * 0.27f, TOP + stripeH * 3.5f, stripeH * 1.3f, paint)
                paint.color = 0xFFFFCC00.toInt()
                canvas.drawPath(starPath(FW * 0.36f, TOP + stripeH * 3.5f, stripeH * 1.1f), paint)
            }
            "BR" -> {
                paint.color = colors[0]
                canvas.drawRect(0f, TOP, FW, TOP + FH, paint)
                paint.color = colors[1]
                val path = Path()
                path.moveTo(FW * 0.5f, TOP + FH * 0.08f)
                path.lineTo(FW * 0.92f, TOP + FH / 2f)
                path.lineTo(FW * 0.5f, TOP + FH * 0.92f)
                path.lineTo(FW * 0.08f, TOP + FH / 2f)
                path.close()
                canvas.drawPath(path, paint)
                paint.color = colors[2]
                canvas.drawCircle(FW * 0.5f, TOP + FH / 2f, FH * 0.23f, paint)
            }
            "CL" -> {
                paint.color = colors[1]
                canvas.drawRect(0f, TOP, FW, TOP + FH / 2f, paint)
                paint.color = colors[0]
                canvas.drawRect(0f, TOP + FH / 2f, FW, TOP + FH, paint)
                paint.color = colors[2]
                canvas.drawRect(0f, TOP, FW * 0.33f, TOP + FH / 2f, paint)
                paint.color = colors[1]
                canvas.drawPath(starPath(FW * 0.165f, TOP + FH * 0.25f, FH * 0.13f), paint)
            }
            "AE" -> {
                val stripeH = FH / 3f
                for (i in 0 until 3) {
                    paint.color = colors[i]
                    canvas.drawRect(FW * 0.28f, TOP + i * stripeH, FW, TOP + (i + 1) * stripeH, paint)
                }
                paint.color = 0xFFEF3340.toInt()
                canvas.drawRect(0f, TOP, FW * 0.28f, TOP + FH, paint)
            }
            "BY" -> {
                paint.color = colors[0]
                canvas.drawRect(0f, TOP, FW, TOP + FH * 2f / 3f, paint)
                paint.color = colors[1]
                canvas.drawRect(0f, TOP + FH * 2f / 3f, FW, TOP + FH, paint)
                // Декоративная полоса слева.
                paint.color = colors[2]
                canvas.drawRect(0f, TOP, FW * 0.12f, TOP + FH, paint)
                paint.color = colors[0]
                canvas.drawRect(FW * 0.045f, TOP, FW * 0.075f, TOP + FH, paint)
            }
            "AU", "NZ" -> {
                paint.color = colors[0]
                canvas.drawRect(0f, TOP, FW, TOP + FH, paint)
                drawUnionJack(canvas, 0f, TOP, FW * 0.5f, FH / 2f, paint)
                paint.color = colors[1]
                canvas.drawPath(starPath(FW * 0.7f, TOP + FH * 0.3f, FH * 0.12f), paint)
                canvas.drawPath(starPath(FW * 0.75f, TOP + FH * 0.62f, FH * 0.12f), paint)
                canvas.drawPath(starPath(FW * 0.6f, TOP + FH * 0.82f, FH * 0.1f), paint)
                if (code == "AU") {
                    canvas.drawPath(starPath(FW * 0.25f, TOP + FH * 0.75f, FH * 0.12f), paint)
                }
            }
            else -> {
                paint.color = colors[0]
                canvas.drawRect(0f, TOP, FW, TOP + FH, paint)
            }
        }
    }

    private fun drawUnionJack(canvas: Canvas, left: Float, top: Float, w: Float, h: Float, paint: Paint) {
        canvas.save()
        canvas.clipRect(left, top, left + w, top + h)
        paint.style = Paint.Style.FILL
        // Фон.
        paint.color = 0xFF012169.toInt()
        canvas.drawRect(left, top, left + w, top + h, paint)
        // Белые диагонали.
        paint.color = 0xFFFFFFFF.toInt()
        paint.strokeWidth = h * 0.22f
        canvas.drawLine(left, top, left + w, top + h, paint)
        canvas.drawLine(left + w, top, left, top + h, paint)
        // Красные диагонали.
        paint.color = 0xFFC8102E.toInt()
        paint.strokeWidth = h * 0.08f
        canvas.drawLine(left, top, left + w, top + h, paint)
        canvas.drawLine(left + w, top, left, top + h, paint)
        // Белый крест.
        paint.color = 0xFFFFFFFF.toInt()
        paint.strokeWidth = h * 0.32f
        canvas.drawLine(left + w / 2f, top, left + w / 2f, top + h, paint)
        canvas.drawLine(left, top + h / 2f, left + w, top + h / 2f, paint)
        // Красный крест.
        paint.color = 0xFFC8102E.toInt()
        paint.strokeWidth = h * 0.18f
        canvas.drawLine(left + w / 2f, top, left + w / 2f, top + h, paint)
        canvas.drawLine(left, top + h / 2f, left + w, top + h / 2f, paint)
        canvas.restore()
    }

    /** Нейтральный «флажок» для неопределённой страны (48x48, цветной). */
    fun paintUnknown(): Bitmap {
        val bitmap = Bitmap.createBitmap(SIZE, SIZE, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        paintGeneric(canvas)
        return bitmap
    }

    /**
     * SmallIcon для статус-бара (48x48, только альфа): Android рендерит
     * smallIcon как монохромную маску, поэтому рисуем белый силуэт —
     * двухбуквенный ISO-код страны. Для неизвестной страны — силуэт
     * «флажка на древке».
     */
    fun paintSmall(code: String?): Bitmap {
        val bitmap = Bitmap.createBitmap(SIZE, SIZE, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        if (code == null) {
            paintPennantGlyph(canvas)
            return bitmap
        }
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xFFFFFFFF.toInt()
            textSize = 30f
            typeface = Typeface.create(Typeface.SANS_SERIF, Typeface.BOLD)
            textAlign = Paint.Align.CENTER
        }
        val x = SIZE / 2f
        val y = SIZE / 2f - (paint.descent() + paint.ascent()) / 2f
        canvas.drawText(code.uppercase(), x, y, paint)
        return bitmap
    }

    /**
     * LargeIcon для шторки: цветной флаг (или нейтральный «флажок»),
     * вырезанный до полосы полотнища 48x32 и увеличенный до 108x72.
     */
    fun paintLarge(code: String?): Bitmap {
        val src = if (code != null) paint(code) else paintUnknown()
        val strip = Bitmap.createBitmap(src, 0, TOP.toInt(), SIZE, FH.toInt())
        return Bitmap.createScaledBitmap(strip, 108, 72, true)
    }

    /** Белый силуэт «флажок на древке» — для smallIcon без известной страны. */
    private fun paintPennantGlyph(canvas: Canvas) {
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        paint.color = 0xFFFFFFFF.toInt()
        // Древко.
        canvas.drawRect(FW * 0.2f, TOP - 4f, FW * 0.28f, TOP + FH + 4f, paint)
        // Полотнище с вырезом («ласточкин хвост»).
        val path = Path()
        path.moveTo(FW * 0.28f, TOP + 1f)
        path.lineTo(FW * 0.88f, TOP + 1f)
        path.lineTo(FW * 0.72f, TOP + FH * 0.35f)
        path.lineTo(FW * 0.88f, TOP + FH * 0.69f)
        path.lineTo(FW * 0.28f, TOP + FH * 0.69f)
        path.close()
        canvas.drawPath(path, paint)
    }

    private fun paintGeneric(canvas: Canvas) {
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        // Нейтральный «флажок» для неизвестной страны: серое полотнище
        // со светлой обводкой на сером древке — видно на любом фоне.
        paint.color = 0xFF757575.toInt()
        canvas.drawRect(FW * 0.16f, TOP + FH * 0.08f, FW * 0.88f, TOP + FH * 0.62f, paint)
        paint.color = 0xFFEEEEEE.toInt()
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = 2f
        canvas.drawRect(FW * 0.16f, TOP + FH * 0.08f, FW * 0.88f, TOP + FH * 0.62f, paint)
        paint.style = Paint.Style.FILL
        paint.color = 0xFFBDBDBD.toInt()
        canvas.drawRect(FW * 0.1f, TOP + FH * 0.04f, FW * 0.16f, TOP + FH * 0.96f, paint)
    }

    private fun starPath(cx: Float, cy: Float, r: Float): Path {
        val path = Path()
        val inner = r * 0.382f
        for (i in 0 until 10) {
            val angle = Math.PI / 2 + i * Math.PI / 5
            val radius = if (i % 2 == 0) r else inner
            val x = cx + (radius * Math.cos(angle)).toFloat()
            val y = cy - (radius * Math.sin(angle)).toFloat()
            if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
        }
        path.close()
        return path
    }

    private fun trianglePath(cx: Float, cy: Float, r: Float, up: Boolean): Path {
        val path = Path()
        for (i in 0 until 3) {
            val angle = if (up) Math.PI / 2 + i * 2 * Math.PI / 3 else -Math.PI / 2 + i * 2 * Math.PI / 3
            val x = cx + (r * Math.cos(angle)).toFloat()
            val y = cy - (r * Math.sin(angle)).toFloat()
            if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
        }
        path.close()
        return path
    }
}
