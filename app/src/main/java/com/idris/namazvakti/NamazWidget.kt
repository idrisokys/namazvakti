package com.idris.namazvakti

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.BroadcastReceiver
import android.content.Intent
import android.widget.RemoteViews
import kotlin.concurrent.thread

class NamazWidget : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        refresh(context, goAsync())
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent) // APPWIDGET_UPDATE -> onUpdate
        when (intent.action) {
            ACTION_REFRESH, Intent.ACTION_TIME_CHANGED, Intent.ACTION_TIMEZONE_CHANGED ->
                refresh(context, goAsync())
        }
    }

    override fun onDisabled(context: Context) {
        (context.getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(refreshIntent(context))
    }

    companion object {
        const val ACTION_REFRESH = "com.idris.namazvakti.WIDGET_REFRESH"

        private fun refreshIntent(c: Context) = PendingIntent.getBroadcast(
            c, 0,
            Intent(c, NamazWidget::class.java).setAction(ACTION_REFRESH),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        /** Tüm widget'ları günceller ve bir sonraki vakitte yeniden güncellenmek üzere alarm kurar. */
        fun refresh(context: Context, pending: BroadcastReceiver.PendingResult? = null) {
            val app = context.applicationContext
            thread {
                try {
                    val mgr = AppWidgetManager.getInstance(app)
                    val ids = mgr.getAppWidgetIds(ComponentName(app, NamazWidget::class.java))
                    if (ids.isEmpty()) return@thread

                    val times = PrayerData.times(app)
                    mgr.updateAppWidget(ids, build(app, times))
                    if (times != null) schedule(app, (System.currentTimeMillis() / 60_000 + 1) * 60_000) // her dakika başı
                } catch (_: Exception) {
                } finally {
                    pending?.finish()
                }
            }
        }

        private const val TARGET = 4 // Akşam

        private fun build(c: Context, times: List<String>?): RemoteViews {
            val v = RemoteViews(c.packageName, R.layout.widget_namaz)
            v.setOnClickPendingIntent(
                R.id.w_root,
                PendingIntent.getActivity(
                    c, 0, Intent(c, MainActivity::class.java),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
            )
            if (times == null) {
                v.setTextViewText(R.id.w_label, "İnternet yok")
                v.setTextViewText(R.id.w_countdown, "--")
                return v
            }
            val now = System.currentTimeMillis()
            var target = PrayerData.at(times[TARGET])
            if (target <= now) target = PrayerData.at(times[TARGET], 1)
            val minutes = ((target - now + 59_999) / 60_000).toInt()
            val h = minutes / 60
            val m = minutes % 60
            v.setTextViewText(R.id.w_label, "${PrayerData.names[TARGET]} vaktine")
            v.setTextViewText(R.id.w_countdown, if (h > 0) "${h}sa ${m}dk" else "${m}dk")
            return v
        }

        private fun schedule(c: Context, at: Long) {
            val am = c.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val pi = refreshIntent(c)
            try {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at + 500, pi)
            } catch (e: SecurityException) {
                am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at + 500, pi)
            }
        }
    }
}
