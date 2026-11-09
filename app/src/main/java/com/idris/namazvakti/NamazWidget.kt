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
                        val w = o.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 110)
                        val h = o.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 180)
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

            // Ölçüler: widget'a sığan EN BÜYÜK kalın yazı boyutları (dp cinsinden hesaplanır, sp'ye çevrilir)
            val fs = c.resources.configuration.fontScale.coerceAtLeast(0.5f)
            fun sp(dp: Float) = (dp / fs).coerceAtLeast(6f)

            val lh = 1.2f                               // satır yüksekliği çarpanı (includeFontPadding=false)
            val innerW = w - 4f                         // kök dolgu
            val free = (h - 4f) - 4f                    // kök dolgu + kartın alt boşluğu
            val cardH = free * 2.2f / 7.2f              // üst kart (weight 2.2)
            val rowsH = free * 5f / 7.2f                // 5 vakit alanı (weight 5)

            // Üst kart: iç ölçüler
            val availW = innerW - 12f - 2f              // kart dolgusu + çerçeve payı
            val textH = cardH - 12f

            // Alt: 5 satır; her satırda vakit adı (sol) + saat (sağ). Kalın yazıda en geniş ad "Akşam" ≈ 3.1em, "00:00" ≈ 2.65em
            val rowH = rowsH / 5f - 4f
            val rowW = innerW - 16f - 6f - 4f           // yatay dolgu + ad-saat boşluğu + pay
            val heightLimit = ((rowH - 3f) / lh).coerceAtLeast(8f)
            val timeDp = minOf(heightLimit, rowW / 5.3f).coerceAtLeast(8f)
            val nameDp = minOf(heightLimit, (rowW - timeDp * 2.65f) / 3.1f).coerceAtLeast(7f)
            for (i in 0 until 5) {
                v.setTextViewTextSize(NAME_IDS[i], TypedValue.COMPLEX_UNIT_SP, sp(nameDp))
                v.setTextViewTextSize(TIME_IDS[i], TypedValue.COMPLEX_UNIT_SP, sp(timeDp))
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
                val label = "İnternet yok"
                val l = minOf(availW / (label.length * 0.55f), textH * 0.3f / lh).coerceAtLeast(8f)
                val big = minOf((textH - l * lh - 2f) / lh, availW / (2 * 0.6f)).coerceAtLeast(12f)
                v.setTextViewTextSize(R.id.w_label, TypedValue.COMPLEX_UNIT_SP, sp(l))
                v.setTextViewTextSize(R.id.w_countdown, TypedValue.COMPLEX_UNIT_SP, sp(big))
                v.setTextViewText(R.id.w_label, label)
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

            // Etiket ("Akşam vaktine"): genişliğe sığan en büyük kalın boyut, kartın yüksekliğinin ~%30'u ile sınırlı
            val label = "${PrayerData.names[idx]} vaktine"
            val labelDp = minOf(availW / (label.length * 0.55f), textH * 0.3f / lh).coerceAtLeast(8f)

            // Kalan süre: tek satır ("10sa 40dk") ya da iki satır ("10sa" / "40dk"); hangisi daha büyük sığıyorsa o
            val remH = textH - labelDp * lh - 2f
            val one = if (hh > 0) "${hh}sa ${mm}dk" else "${mm}dk"
            val two = if (hh > 0) "${hh}sa\n${mm}dk" else one
            val cw = 0.58f                              // kalın yazıda karakter başına genişlik (em)
            val c1 = minOf(remH / lh, availW / (one.length * cw))
            val longest = if (hh > 0) maxOf("${hh}sa".length, "${mm}dk".length) else one.length
            val c2 = minOf(remH / (lh * 2f + 0.05f), availW / (longest * cw))
            val useTwo = hh > 0 && c2 > c1
            val countDp = (if (useTwo) c2 else c1).coerceAtLeast(12f)
            v.setTextViewTextSize(R.id.w_countdown, TypedValue.COMPLEX_UNIT_SP, sp(countDp))
            v.setTextViewTextSize(R.id.w_label, TypedValue.COMPLEX_UNIT_SP, sp(labelDp))
            v.setTextViewText(R.id.w_label, label)
            v.setTextViewText(R.id.w_countdown, if (useTwo) two else one)

            // 5 vakit: İmsak, Öğle, İkindi, Akşam, Yatsı (Güneş hariç); sıradaki vakit altın çerçeveli
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
