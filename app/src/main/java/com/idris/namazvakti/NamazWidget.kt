package com.idris.namazvakti

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.BroadcastReceiver
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.util.TypedValue
import android.view.View
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
        private val TILE_IDS = intArrayOf(R.id.p0, R.id.p1, R.id.p2, R.id.p3, R.id.p4)
        private val ICON_IDS = intArrayOf(R.id.p0_icon, R.id.p1_icon, R.id.p2_icon, R.id.p3_icon, R.id.p4_icon)
        private val ACCENT = 0xFFFFD54F.toInt()
        private val NAME_COLOR = 0xFFE3ECF7.toInt()

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
                        val w = o.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 250)
                        val h = o.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 130)
                        mgr.updateAppWidget(id, build(app, times, w, h))
                    }
                    if (times != null) schedule(app, (System.currentTimeMillis() / 60_000 + 1) * 60_000) // her dakika başı
                } catch (_: Exception) {
                } finally {
                    pending?.finish()
                }
            }
        }

        private fun build(c: Context, times: List<String>?, w: Int, h: Int): RemoteViews {
            val v = RemoteViews(c.packageName, R.layout.widget_namaz)

            // Ölçüler (dp ≈ sp): kart yüksekliği ~%55, kutucuklar ~%45
            val compact = h < 125                       // alçak widget: kutucuk ikonlarını gizle
            val cardH = (h - 8) * 0.55f
            val tileW = (w - 8 - 5 * 6) / 5.0f
            val tileH = (h - 8) * 0.45f
            val timeSp = minOf(tileW / 3.3f, tileH / (if (compact) 2.2f else 3.2f)).coerceIn(9f, 20f)
            val nameSp = (timeSp * 0.72f).coerceIn(8f, 14f)
            val labelSp = (cardH * 0.17f).coerceIn(9f, 16f)

            for (i in 0 until 5) {
                v.setTextViewTextSize(NAME_IDS[i], TypedValue.COMPLEX_UNIT_SP, nameSp)
                v.setTextViewTextSize(TIME_IDS[i], TypedValue.COMPLEX_UNIT_SP, timeSp)
                v.setTextViewText(NAME_IDS[i], PrayerData.names[SHOWN[i]])
                v.setViewVisibility(ICON_IDS[i], if (compact) View.GONE else View.VISIBLE)
            }
            v.setViewVisibility(R.id.w_wave, if (cardH < 60f) View.GONE else View.VISIBLE)
            v.setTextViewTextSize(R.id.w_label, TypedValue.COMPLEX_UNIT_SP, labelSp)

            v.setOnClickPendingIntent(
                R.id.w_root,
                PendingIntent.getActivity(
                    c, 0, Intent(c, MainActivity::class.java),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
            )

            if (times == null) {
                v.setTextViewTextSize(R.id.w_countdown, TypedValue.COMPLEX_UNIT_SP, (cardH * 0.4f).coerceIn(14f, 40f))
                v.setTextViewText(R.id.w_label, "İnternet yok")
                v.setTextViewText(R.id.w_countdown, "--")
                for (i in 0 until 5) {
                    v.setTextViewText(TIME_IDS[i], "--:--")
                    v.setInt(TILE_IDS[i], "setBackgroundResource", R.drawable.glass_tile)
                }
                return v
            }

            val now = System.currentTimeMillis()
            val (idx, target) = PrayerData.next(times) // sıradaki vakit (Yatsıdan sonra yarının İmsak'ı)
            val minutes = ((target - now + 59_999) / 60_000).toInt()
            val hh = minutes / 60
            val mm = minutes % 60
            val text = if (hh > 0) "${hh}sa ${mm}dk" else "${mm}dk"

            // Kalan süre: yükseklik ve genişliğe sığacak en büyük boyut
            val availW = w - 8 - 52 - 20 - 20f         // kart dolgusu + ikon + ayırıcı
            val countSp = minOf(cardH * 0.46f, availW / (text.length * 0.56f)).coerceIn(14f, 44f)
            v.setTextViewTextSize(R.id.w_countdown, TypedValue.COMPLEX_UNIT_SP, countSp)
            v.setTextViewText(R.id.w_label, "${PrayerData.names[idx]} vaktine")
            v.setTextViewText(R.id.w_countdown, text)

            // Alt satır: İmsak, Öğle, İkindi, Akşam, Yatsı (Güneş hariç); sıradaki vakit altın çerçeveli
            for (i in 0 until 5) {
                val k = SHOWN[i]
                val active = k == idx
                v.setTextViewText(TIME_IDS[i], times[k])
                v.setTextColor(TIME_IDS[i], if (active) ACCENT else Color.WHITE)
                v.setTextColor(NAME_IDS[i], if (active) ACCENT else NAME_COLOR)
                v.setInt(
                    TILE_IDS[i], "setBackgroundResource",
                    if (active) R.drawable.glass_tile_active else R.drawable.glass_tile
                )
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
