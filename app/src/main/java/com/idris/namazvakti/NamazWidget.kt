package com.idris.namazvakti

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.BroadcastReceiver
import android.content.Intent
import android.os.Bundle
import android.util.TypedValue
import android.widget.RemoteViews
import kotlin.concurrent.thread

class NamazWidget : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        refresh(context, goAsync())
    }

    override fun onAppWidgetOptionsChanged(
        context: Context, manager: AppWidgetManager, id: Int, newOptions: Bundle
    ) {
        refresh(context, goAsync()) // boyut değişti: yazı boyutlarını yeniden hesapla
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

        // PrayerData.names indeksleri: 0 İmsak, 1 Güneş, 2 Öğle, 3 İkindi, 4 Akşam, 5 Yatsı
        private val SHOWN = intArrayOf(0, 2, 3, 4, 5)
        private val NAME_IDS = intArrayOf(R.id.p0_name, R.id.p1_name, R.id.p2_name, R.id.p3_name, R.id.p4_name)
        private val TIME_IDS = intArrayOf(R.id.p0_time, R.id.p1_time, R.id.p2_time, R.id.p3_time, R.id.p4_time)
        private val ACCENT = 0xFFFFD54F.toInt()

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
                    for (id in ids) {
                        val o = mgr.getAppWidgetOptions(id)
                        val w = o.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 60)
                        val h = o.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 60)
                        // Üst bölüm (etiket + kalan süre) yüksekliğin ~%55'i; alt bölüm 5 sütun
                        val main = minOf((w - 16) / 5.0f, (h * 0.55f - 8) / 1.8f).coerceIn(10f, 60f)
                        val colW = (w - 16) / 5.0f
                        val time = minOf(colW / 3.0f, (h * 0.45f - 8) / 2.6f).coerceIn(8f, 24f)
                        mgr.updateAppWidget(
                            id,
                            build(app, times, main, (main * 0.45f).coerceAtLeast(8f), time, (time * 0.65f).coerceAtLeast(7f))
                        )
                    }
                    if (times != null) schedule(app, (System.currentTimeMillis() / 60_000 + 1) * 60_000) // her dakika başı
                } catch (_: Exception) {
                } finally {
                    pending?.finish()
                }
            }
        }

        private fun build(
            c: Context, times: List<String>?,
            mainSp: Float, labelSp: Float, timeSp: Float, nameSp: Float
        ): RemoteViews {
            val v = RemoteViews(c.packageName, R.layout.widget_namaz)
            v.setTextViewTextSize(R.id.w_countdown, TypedValue.COMPLEX_UNIT_SP, mainSp)
            v.setTextViewTextSize(R.id.w_label, TypedValue.COMPLEX_UNIT_SP, labelSp)
            for (i in 0 until 5) {
                v.setTextViewTextSize(NAME_IDS[i], TypedValue.COMPLEX_UNIT_SP, nameSp)
                v.setTextViewTextSize(TIME_IDS[i], TypedValue.COMPLEX_UNIT_SP, timeSp)
                v.setTextViewText(NAME_IDS[i], PrayerData.names[SHOWN[i]])
            }
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
                for (i in 0 until 5) v.setTextViewText(TIME_IDS[i], "--:--")
                return v
            }
            val now = System.currentTimeMillis()
            val (idx, target) = PrayerData.next(times) // sıradaki vakit (Yatsıdan sonra yarının İmsak'ı)
            val minutes = ((target - now + 59_999) / 60_000).toInt()
            val h = minutes / 60
            val m = minutes % 60
            v.setTextViewText(R.id.w_label, "${PrayerData.names[idx]} vaktine")
            v.setTextViewText(R.id.w_countdown, if (h > 0) "${h}sa ${m}dk" else "${m}dk")

            // Alt satır: İmsak, Öğle, İkindi, Akşam, Yatsı (Güneş hariç); sıradaki vakit vurgulanır
            for (i in 0 until 5) {
                val k = SHOWN[i]
                val active = k == idx
                v.setTextViewText(TIME_IDS[i], times[k])
                v.setTextColor(TIME_IDS[i], if (active) ACCENT else 0xFFFFFFFF.toInt())
                v.setTextColor(NAME_IDS[i], if (active) ACCENT else 0xFFC9D6E3.toInt())
            }
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
