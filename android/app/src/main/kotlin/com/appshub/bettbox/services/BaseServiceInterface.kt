package com.appshub.bettbox.services

import android.annotation.SuppressLint
import android.app.Notification
import android.app.Notification.FOREGROUND_SERVICE_IMMEDIATE
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import com.appshub.bettbox.GlobalState
import com.appshub.bettbox.R
import com.appshub.bettbox.models.VpnOptions
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.withContext
import android.content.ComponentName
import android.content.Intent

import android.graphics.BitmapFactory
import com.appshub.bettbox.plugins.VpnPlugin

interface BaseServiceInterface {
    suspend fun start(options: VpnOptions): Int
    fun stop()
    suspend fun startForeground()
}

fun buildNotificationActionPendingIntent(
    service: Service,
    action: String,
    requestCode: Int
): PendingIntent {
    val intent = Intent(service, service.javaClass).apply { this.action = action }
    val flags = if (Build.VERSION.SDK_INT >= 31) {
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
    } else {
        PendingIntent.FLAG_UPDATE_CURRENT
    }
    return PendingIntent.getService(service, requestCode, intent, flags)
}

fun Service.handleNotificationControlAction(intent: Intent?): Boolean {
    return when (intent?.action) {
        GlobalState.NOTIFICATION_ACTION_STOP -> {
            GlobalState.handleStop()
            true
        }
        GlobalState.NOTIFICATION_ACTION_RESTART -> {
            GlobalState.handleRestart()
            true
        }
        GlobalState.NOTIFICATION_ACTION_START -> {
            VpnPlugin.resumeFromNotification()
            true
        }
        GlobalState.NOTIFICATION_ACTION_PAUSE -> {
            val minutes = intent
                ?.getIntExtra("pauseMinutes", GlobalState.getLastPauseMinutes())
                ?: GlobalState.getLastPauseMinutes()
            VpnPlugin.handlePause(minutes)
            true
        }
        else -> false
    }
}

/// Заголовок и текст уведомления с учётом паузы: в паузе показываем,
/// во сколько VPN поднимется автоматически.
fun Service.notificationTitleAndContent(isSuspended: Boolean): Pair<String, String> {
    return when {
        isSuspended && GlobalState.isPaused() -> {
            val resumesAt = java.text.SimpleDateFormat("HH:mm", java.util.Locale.getDefault())
                .format(java.util.Date(GlobalState.pauseUntilWallClock))
            getString(R.string.notification_paused_title) to
                getString(R.string.notification_resumes_at, resumesAt)
        }
        isSuspended ->
            getString(R.string.core_suspended) to
                getString(R.string.smart_auto_stop_service_running)
        else ->
            getString(R.string.core_connected) to
                getString(R.string.service_running)
    }
}

suspend fun Service.createBettboxNotificationBuilder(
    isSuspended: Boolean = GlobalState.isSmartStopped,
    isHighPriority: Boolean = GlobalState.isNotificationHighPriority
): NotificationCompat.Builder =
    withContext(Dispatchers.IO) {
        val defaultComponent = ComponentName(packageName, "com.appshub.bettbox.MainActivity")
        val lightComponent = ComponentName(packageName, "com.appshub.bettbox.MainActivityLight")
        val darkComponent = ComponentName(packageName, "com.appshub.bettbox.MainActivityDark")

        val targetComponent = NotificationComponentCache.get(packageManager, defaultComponent, lightComponent, darkComponent)

        android.util.Log.d("Notification", "Using ${targetComponent.className}")

        val intent = Intent().apply {
            component = targetComponent
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }

        val flags = if (Build.VERSION.SDK_INT >= 31) {
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val pendingIntent = withContext(Dispatchers.Main) {
            PendingIntent.getActivity(this@createBettboxNotificationBuilder, 0, intent, flags)
        }

        val isDark = targetComponent == darkComponent
        val largeIconRes = if (isDark) {
            R.mipmap.ic_launcher
        } else {
            R.mipmap.ic_launcher_light
        }

        val largeIconBitmap = runCatching {
            BitmapFactory.decodeResource(resources, largeIconRes)
        }.getOrNull()

        val channelId = when {
            isSuspended -> GlobalState.NOTIFICATION_CHANNEL_SUSPENDED
            isHighPriority -> GlobalState.NOTIFICATION_CHANNEL_HIGH
            else -> GlobalState.NOTIFICATION_CHANNEL
        }
        val priority = if (isSuspended || isHighPriority) NotificationCompat.PRIORITY_HIGH else NotificationCompat.PRIORITY_LOW

        NotificationCompat.Builder(this@createBettboxNotificationBuilder, channelId).apply {
            setSmallIcon(R.drawable.ic)
            if (largeIconBitmap != null) {
                setLargeIcon(largeIconBitmap)
            }
            setContentTitle("Bettbox")
            setContentIntent(pendingIntent)
            setCategory(NotificationCompat.CATEGORY_SERVICE)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                foregroundServiceBehavior = FOREGROUND_SERVICE_IMMEDIATE
            }
            setOngoing(true)
            setShowWhen(true)
            setOnlyAlertOnce(true)
            setPriority(priority)
            if (isSuspended) {
                addAction(
                    R.drawable.ic_notif_start,
                    getString(
                        if (GlobalState.isPaused()) R.string.notification_action_resume
                        else R.string.notification_action_start
                    ),
                    buildNotificationActionPendingIntent(
                        this@createBettboxNotificationBuilder,
                        GlobalState.NOTIFICATION_ACTION_START,
                        13
                    )
                )
                if (GlobalState.isPaused()) {
                    // В паузе кнопку «Стоп» оставляем — отменить паузу и выключиться.
                    addAction(
                        R.drawable.ic_notif_stop,
                        getString(R.string.notification_action_stop),
                        buildNotificationActionPendingIntent(
                            this@createBettboxNotificationBuilder,
                            GlobalState.NOTIFICATION_ACTION_STOP,
                            11
                        )
                    )
                }
            } else {
                addAction(
                    R.drawable.ic_notif_pause,
                    getString(R.string.notification_action_pause, GlobalState.getLastPauseMinutes()),
                    buildNotificationActionPendingIntent(
                        this@createBettboxNotificationBuilder,
                        GlobalState.NOTIFICATION_ACTION_PAUSE,
                        14
                    )
                )
                addAction(
                    R.drawable.ic_notif_stop,
                    getString(R.string.notification_action_stop),
                    buildNotificationActionPendingIntent(
                        this@createBettboxNotificationBuilder,
                        GlobalState.NOTIFICATION_ACTION_STOP,
                        11
                    )
                )
                addAction(
                    R.drawable.ic_notif_restart,
                    getString(R.string.notification_action_restart),
                    buildNotificationActionPendingIntent(
                        this@createBettboxNotificationBuilder,
                        GlobalState.NOTIFICATION_ACTION_RESTART,
                        12
                    )
                )
            }
        }
    }

fun Service.ensureNotificationChannel(
    isSuspended: Boolean = GlobalState.isSmartStopped,
    isHighPriority: Boolean = GlobalState.isNotificationHighPriority
) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
    val manager = getSystemService(NotificationManager::class.java) ?: return
    val channelId = when {
        isSuspended -> GlobalState.NOTIFICATION_CHANNEL_SUSPENDED
        isHighPriority -> GlobalState.NOTIFICATION_CHANNEL_HIGH
        else -> GlobalState.NOTIFICATION_CHANNEL
    }
    val channel = manager.getNotificationChannel(channelId)
    if (channel == null) {
        val importance = when {
            isSuspended -> NotificationManager.IMPORTANCE_DEFAULT
            isHighPriority -> NotificationManager.IMPORTANCE_HIGH
            else -> NotificationManager.IMPORTANCE_LOW
        }
        val name = when {
            isSuspended -> "Bettbox Suspended Service"
            isHighPriority -> "Bettbox High Priority Service"
            else -> "Bettbox Service"
        }
        val newChannel = NotificationChannel(channelId, name, importance).apply {
            setShowBadge(false)
            if (isSuspended || isHighPriority) {
                setSound(null, null)
                enableVibration(false)
            }
        }
        manager.createNotificationChannel(newChannel)
    }
}

@SuppressLint("ForegroundServiceType")
fun Service.startForeground(notification: Notification, useSpecialType: Boolean = true) {
    ensureNotificationChannel(GlobalState.isSmartStopped, GlobalState.isNotificationHighPriority)

    val type = if (Build.VERSION.SDK_INT >= 34 && useSpecialType && !GlobalState.isSmartStopped) {
        android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
    } else {
        0
    }

    runCatching {
        if (type != 0) {
            startForeground(GlobalState.NOTIFICATION_ID, notification, type)
        } else {
            startForeground(GlobalState.NOTIFICATION_ID, notification)
        }
    }.onFailure {
        android.util.Log.e("BaseServiceInterface", "startForeground failed: ${it.message}")
        runCatching {
            startForeground(GlobalState.NOTIFICATION_ID, notification)
        }.onFailure { fallbackErr ->
            android.util.Log.e("BaseServiceInterface", "startForeground fallback failed: ${fallbackErr.message}")
        }
    }
}
