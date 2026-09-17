package com.appshub.bettbox.receivers

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import com.appshub.bettbox.GlobalState
import com.appshub.bettbox.plugins.VpnPlugin

/// Резервный механизм автовозобновления паузы VPN.
/// Основной таймер живёт в VpnPlugin (процесс приложения держит
/// foreground-сервис и не умирает), будильник подстраховывает на случай,
/// если процесс был убит системой и снова проснулся.
class PauseResumeReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "PauseResumeReceiver"
        private const val ACTION_PAUSE_EXPIRED = "com.appshub.bettbox.action.PAUSE_EXPIRED"
        private const val REQUEST_CODE = 2001

        private fun pendingIntent(context: Context): PendingIntent {
            val intent = Intent(context, PauseResumeReceiver::class.java).apply {
                action = ACTION_PAUSE_EXPIRED
            }
            val flags = if (Build.VERSION.SDK_INT >= 31) {
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
            return PendingIntent.getBroadcast(context, REQUEST_CODE, intent, flags)
        }

        fun scheduleResumption(context: Context, triggerAtMillis: Long) {
            val alarmManager =
                context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
            val pi = pendingIntent(context)
            runCatching {
                alarmManager.setExactAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    triggerAtMillis,
                    pi
                )
            }.getOrElse {
                // Без SCHEDULE_EXACT_ALARM на Android 12+ — неточная будилка:
                // основной таймер в процессе приложения сработает вовремя.
                runCatching {
                    alarmManager.setAndAllowWhileIdle(
                        AlarmManager.RTC_WAKEUP,
                        triggerAtMillis,
                        pi
                    )
                }.onFailure { err ->
                    android.util.Log.e(TAG, "scheduleResumption failed: ${err.message}")
                }
            }
        }

        fun cancelResumption(context: Context) {
            val alarmManager =
                context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
            runCatching { alarmManager.cancel(pendingIntent(context)) }
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_PAUSE_EXPIRED) return

        // Восстановить состояние паузы, если процесс пересоздавался.
        GlobalState.restorePauseFromPrefs()
        val until = GlobalState.pauseUntilWallClock
        if (until == 0L) return

        val now = System.currentTimeMillis()
        if (now < until) {
            // Будильник сработал раньше времени (перезагрузка/Doze) — перепланировать.
            scheduleResumption(context, until)
            return
        }

        runCatching {
            VpnPlugin.resumeIfPausedDue()
        }.onFailure {
            android.util.Log.e(TAG, "resumeIfPausedDue failed: ${it.message}")
        }
    }
}
