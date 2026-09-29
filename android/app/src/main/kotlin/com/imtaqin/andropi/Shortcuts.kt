package com.imtaqin.andropi

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.os.Build
import android.service.quicksettings.TileService
import android.widget.RemoteViews

private fun launchIntent(context: Context, action: String) =
    Intent(context, MainActivity::class.java).setAction(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)

/** Home-screen widget: start a chat or talk to pi. */
class QuickWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val views = RemoteViews(context.packageName, R.layout.widget_quick).apply {
            setOnClickPendingIntent(
                R.id.widget_new_chat,
                PendingIntent.getActivity(context, 1, launchIntent(context, MainActivity.ACTION_NEW_CHAT), PendingIntent.FLAG_IMMUTABLE),
            )
            setOnClickPendingIntent(
                R.id.widget_voice,
                PendingIntent.getActivity(context, 2, launchIntent(context, MainActivity.ACTION_VOICE), PendingIntent.FLAG_IMMUTABLE),
            )
        }
        for (id in ids) manager.updateAppWidget(id, views)
    }
}

/** Quick Settings tile that opens a new chat. */
class NewChatTile : TileService() {
    override fun onClick() {
        super.onClick()
        val intent = launchIntent(this, MainActivity.ACTION_NEW_CHAT)
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(PendingIntent.getActivity(this, 3, intent, PendingIntent.FLAG_IMMUTABLE))
        } else {
            @Suppress("DEPRECATION", "StartActivityAndCollapseDeprecated")
            startActivityAndCollapse(intent)
        }
    }
}
