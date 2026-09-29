package com.imtaqin.andropi

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Keeps the app process alive while the agent is working so a long run is not
 * killed when the user switches apps. The process itself lives in AgentRuntime.
 */
class AgentService : Service() {
    companion object {
        private const val CHANNEL = "agent"
        private const val ID = 1

        fun setActive(context: Context, active: Boolean, text: String = "Agent is working") {
            val intent = Intent(context, AgentService::class.java).putExtra("text", text)
            if (active) context.startForegroundService(intent)
            else context.stopService(intent)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Agent activity", NotificationManager.IMPORTANCE_LOW)
        )
        val open = PendingIntent.getActivity(
            this, 0,
            packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notification = Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_agent)
            .setContentTitle("AndroPI")
            .setContentText(intent?.getStringExtra("text") ?: "Agent is working")
            .setContentIntent(open)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(ID, notification)
        }
        return START_NOT_STICKY
    }
}
