package com.idris.namazvakti

import android.annotation.SuppressLint
import android.app.Activity
import android.app.AlertDialog
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.text.style.RelativeSizeSpan
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import kotlin.concurrent.thread

class MainActivity : Activity() {

    private val names = listOf("İmsak", "Güneş", "Öğle", "İkindi", "Akşam", "Yatsı")
    private val keys = listOf("Fajr", "Sunrise", "Dhuhr", "Asr", "Maghrib", "Isha")

    private val iller = listOf(
        "Adana", "Adıyaman", "Afyonkarahisar", "Ağrı", "Aksaray", "Amasya", "Ankara", "Antalya",
        "Ardahan", "Artvin", "Aydın", "Balıkesir", "Bartın", "Batman", "Bayburt", "Bilecik",
        "Bingöl", "Bitlis", "Bolu", "Burdur", "Bursa", "Çanakkale", "Çankırı", "Çorum",
        "Denizli", "Diyarbakır", "Düzce", "Edirne", "Elazığ", "Erzincan", "Erzurum", "Eskişehir",
        "Gaziantep", "Giresun", "Gümüşhane", "Hakkari", "Hatay", "Iğdır", "Isparta", "İstanbul",
        "İzmir", "Kahramanmaraş", "Karabük", "Karaman", "Kars", "Kastamonu", "Kayseri", "Kilis",
        "Kırıkkale", "Kırklareli", "Kırşehir", "Kocaeli", "Konya", "Kütahya", "Malatya", "Manisa",
        "Mardin", "Mersin", "Muğla", "Muş", "Nevşehir", "Niğde", "Ordu", "Osmaniye",
        "Rize", "Sakarya", "Samsun", "Siirt", "Sinop", "Sivas", "Şanlıurfa", "Şırnak",
        "Tekirdağ", "Tokat", "Trabzon", "Tunceli", "Uşak", "Van", "Yalova", "Yozgat", "Zonguldak"
    )

    private val prefs by lazy { getSharedPreferences("namaz", MODE_PRIVATE) }
    private val handler = Handler(Looper.getMainLooper())
    private var times: List<String>? = null

    private lateinit var cityView: TextView
    private lateinit var minutesView: TextView
    private lateinit var labelView: TextView
    private lateinit var panel: LinearLayout
    private val rows = ArrayList<TextView>()

    private val ticker = object : Runnable {
        override fun run() {
            refreshCountdown()
            handler.postDelayed(this, 10_000)
        }
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    @SuppressLint("ClickableViewAccessibility")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val root = FrameLayout(this).apply { setBackgroundColor(Color.parseColor("#0F1B2D")) }

        cityView = TextView(this).apply {
            textSize = 18f
            setTextColor(Color.WHITE)
            setPadding(dp(16), dp(16), dp(16), dp(16))
            setOnLongClickListener { showCityPicker(); true }
        }
        root.addView(cityView, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.TOP or Gravity.END).apply { topMargin = dp(24) })

        val center = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
        }

        labelView = TextView(this).apply {
            textSize = 20f
            setTextColor(Color.parseColor("#9FB3C8"))
            gravity = Gravity.CENTER
        }
        minutesView = TextView(this).apply {
            textSize = 88f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            setPadding(dp(16), dp(8), dp(16), dp(8))
            // Basılı tutunca vakitler görünür, bırakınca gizlenir
            setOnTouchListener { v, e ->
                when (e.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        v.parent.requestDisallowInterceptTouchEvent(true)
                        panel.visibility = View.VISIBLE
                    }
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL ->
                        panel.visibility = View.INVISIBLE
                }
                true
            }
        }

        panel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            visibility = View.INVISIBLE
            setPadding(dp(24), dp(24), dp(24), dp(8))
        }
        for (i in names.indices) {
            val tv = TextView(this).apply {
                textSize = 20f
                setTextColor(Color.parseColor("#9FB3C8"))
                setPadding(0, dp(4), 0, dp(4))
            }
            rows.add(tv)
            panel.addView(tv)
        }

        center.addView(labelView)
        center.addView(minutesView)
        center.addView(panel)
        root.addView(center, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.CENTER))

        setContentView(root)
        updateCityText()
        loadTimes()
    }

    override fun onResume() {
        super.onResume()
        loadTimes()
        handler.post(ticker)
    }

    override fun onPause() {
        super.onPause()
        handler.removeCallbacks(ticker)
    }

    private fun city() = prefs.getString("city", "İstanbul") ?: "İstanbul"

    private fun updateCityText() { cityView.text = city() }

    private fun showCityPicker() {
        AlertDialog.Builder(this)
            .setTitle("İl seç")
            .setItems(iller.toTypedArray()) { _, which ->
                prefs.edit().putString("city", iller[which]).apply()
                times = null
                updateCityText()
                loadTimes()
            }
            .show()
    }

    private fun today(): String = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())

    private fun ascii(s: String): String {
        val from = "çğıöşüÇĞİÖŞÜ"
        val to = "cgiosuCGIOSU"
        val sb = StringBuilder()
        for (c in s) { val i = from.indexOf(c); sb.append(if (i >= 0) to[i] else c) }
        return sb.toString()
    }

    private fun loadTimes() {
        val cacheKey = today() + "|" + city()
        val cached = prefs.getString("cache_$cacheKey", null)
        if (cached != null) {
            times = cached.split(",")
            refreshCountdown()
            return
        }
        val c = city()
        thread {
            try {
                val url = "https://api.aladhan.com/v1/timingsByCity?city=" +
                        URLEncoder.encode(ascii(c), "UTF-8") + "&country=Turkey&method=13"
                val conn = URL(url).openConnection() as HttpURLConnection
                conn.connectTimeout = 10_000
                conn.readTimeout = 10_000
                val body = conn.inputStream.bufferedReader().readText()
                val t = JSONObject(body).getJSONObject("data").getJSONObject("timings")
                val list = keys.map { t.getString(it).substring(0, 5) }
                prefs.edit().putString("cache_$cacheKey", list.joinToString(",")).apply()
                runOnUiThread {
                    if (c == city()) { times = list; refreshCountdown() }
                }
            } catch (e: Exception) {
                runOnUiThread { labelView.text = "İnternet bağlantısı gerekli" }
            }
        }
    }

    private fun at(time: String, addDays: Int = 0): Long {
        val (h, m) = time.split(":").map { it.toInt() }
        return Calendar.getInstance().apply {
            add(Calendar.DAY_OF_YEAR, addDays)
            set(Calendar.HOUR_OF_DAY, h); set(Calendar.MINUTE, m)
            set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }.timeInMillis
    }

    private fun formatRemaining(totalMinutes: Int): CharSequence {
        val h = totalMinutes / 60
        val m = totalMinutes % 60
        val sb = SpannableStringBuilder()
        fun number(n: Int) = sb.append(n.toString())
        fun unit(u: String) {
            val start = sb.length
            sb.append(u)
            sb.setSpan(RelativeSizeSpan(0.27f), start, sb.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            sb.setSpan(ForegroundColorSpan(Color.parseColor("#9FB3C8")), start, sb.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        if (h > 0) { number(h); unit(" saat "); }
        number(m); unit(" dakika")
        return sb
    }

    private fun refreshCountdown() {
        val t = times ?: return
        val now = System.currentTimeMillis()
        var next = t.indexOfFirst { at(it) > now }
        val target = if (next >= 0) at(t[next]) else { next = 0; at(t[0], 1) }
        val minutes = ((target - now + 59_999) / 60_000).toInt()

        minutesView.text = formatRemaining(minutes)
        labelView.text = "${names[next]} vaktine kalan"
        for (i in names.indices) {
            rows[i].text = "${names[i].padEnd(8)}  ${t[i]}"
            rows[i].setTextColor(if (i == next) Color.WHITE else Color.parseColor("#9FB3C8"))
        }
    }
}
