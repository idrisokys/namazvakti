package com.idris.namazvakti

import android.content.Context
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/** Uygulama ve widget'ın ortak kullandığı vakit verisi (aynı önbelleği paylaşır). */
object PrayerData {
    val names = listOf("İmsak", "Güneş", "Öğle", "İkindi", "Akşam", "Yatsı")
    val keys = listOf("Fajr", "Sunrise", "Dhuhr", "Asr", "Maghrib", "Isha")

    private fun prefs(c: Context) = c.getSharedPreferences("namaz", Context.MODE_PRIVATE)

    fun city(c: Context): String = prefs(c).getString("city", "İstanbul") ?: "İstanbul"

    private fun today(): String = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())

    private fun ascii(s: String): String {
        val from = "çğıöşüÇĞİÖŞÜ"
        val to = "cgiosuCGIOSU"
        val sb = StringBuilder()
        for (ch in s) { val i = from.indexOf(ch); sb.append(if (i >= 0) to[i] else ch) }
        return sb.toString()
    }

    /** Önbellekten okur; yoksa internetten çeker. Arka plan thread'inde çağrılmalı. Başarısızsa null. */
    fun times(c: Context): List<String>? {
        val city = city(c)
        val cacheKey = today() + "|" + city
        prefs(c).getString("cache_$cacheKey", null)?.let { return it.split(",") }
        return try {
            val url = "https://api.aladhan.com/v1/timingsByCity?city=" +
                    URLEncoder.encode(ascii(city), "UTF-8") + "&country=Turkey&method=13"
            val conn = URL(url).openConnection() as HttpURLConnection
            conn.connectTimeout = 10_000
            conn.readTimeout = 10_000
            val body = conn.inputStream.bufferedReader().readText()
            val t = JSONObject(body).getJSONObject("data").getJSONObject("timings")
            val list = keys.map { t.getString(it).substring(0, 5) }
            prefs(c).edit().putString("cache_$cacheKey", list.joinToString(",")).apply()
            list
        } catch (e: Exception) {
            null
        }
    }

    fun at(time: String, addDays: Int = 0): Long {
        val (h, m) = time.split(":").map { it.toInt() }
        return Calendar.getInstance().apply {
            add(Calendar.DAY_OF_YEAR, addDays)
            set(Calendar.HOUR_OF_DAY, h); set(Calendar.MINUTE, m)
            set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }.timeInMillis
    }

    /** Sıradaki vaktin (indeks, zaman damgası) değeri. Yatsıdan sonra yarının İmsak'ı. */
    fun next(t: List<String>): Pair<Int, Long> {
        val now = System.currentTimeMillis()
        val i = t.indexOfFirst { at(it) > now }
        return if (i >= 0) i to at(t[i]) else 0 to at(t[0], 1)
    }
}
