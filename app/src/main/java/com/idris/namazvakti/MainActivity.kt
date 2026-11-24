package com.idris.namazvakti

import android.annotation.SuppressLint
import android.app.Activity
import android.app.AlertDialog
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.RelativeSizeSpan
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
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
    private lateinit var dateView: TextView
    private lateinit var minutesView: TextView
    private lateinit var labelView: TextView
    private lateinit var sunriseView: TextView
    private val tileBoxes = ArrayList<LinearLayout>()
    private val tileNames = ArrayList<TextView>()
    private val tileTimes = ArrayList<TextView>()

    // names/keys indeksleri: 0 İmsak, 1 Güneş, 2 Öğle, 3 İkindi, 4 Akşam, 5 Yatsı
    private val shown = intArrayOf(0, 2, 3, 4, 5)
    private val tileIcons = intArrayOf(
        R.drawable.ic_vakit_imsak, R.drawable.ic_vakit_ogle, R.drawable.ic_vakit_ikindi,
        R.drawable.ic_vakit_aksam, R.drawable.ic_vakit_yatsi
    )
    private val gold = Color.parseColor("#FFD54F")
    private val soft = Color.parseColor("#E3ECF7")

    private val ticker = object : Runnable {
        override fun run() {
            refreshCountdown()
            handler.postDelayed(this, 10_000)
        }
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    private fun shadow(tv: TextView) = tv.setShadowLayer(10f, 0f, 2f, Color.BLACK)

    private fun glass(radiusDp: Int, fill: Int, strokeDp: Int = 1, stroke: Int = Color.parseColor("#40FFFFFF")) =
        GradientDrawable().apply {
            setColor(fill)
            cornerRadius = dp(radiusDp).toFloat()
            setStroke(dp(strokeDp), stroke)
        }

    @SuppressLint("ClickableViewAccessibility")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Durum ve gezinme çubuğunu şeffaf yap, resim ekranın tamamını kaplasın
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
        window.decorView.systemUiVisibility =
            View.SYSTEM_UI_FLAG_LAYOUT_STABLE or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
        val statusId = resources.getIdentifier("status_bar_height", "dimen", "android")
        val statusH = if (statusId > 0) resources.getDimensionPixelSize(statusId) else dp(24)
        val navId = resources.getIdentifier("navigation_bar_height", "dimen", "android")
        val navH = if (navId > 0) resources.getDimensionPixelSize(navId) else 0

        val root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }

        // Arka plan resmi
        root.addView(ImageView(this).apply {
            setImageResource(R.drawable.arkaplan)
            scaleType = ImageView.ScaleType.CENTER_CROP
        }, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))

        // Yazıların okunması için hafif mavi-lacivert karartma (üst ve alt daha koyu)
        root.addView(View(this).apply {
            background = GradientDrawable(
                GradientDrawable.Orientation.TOP_BOTTOM,
                intArrayOf(Color.parseColor("#990A1A38"), Color.parseColor("#220A1A38"),
                    Color.parseColor("#220A1A38"), Color.parseColor("#B30A1A38")))
        }, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))

        // Sol üst: tarih (il hapıyla birebir aynı görünüm)
        dateView = TextView(this).apply {
            textSize = 15f
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            setTextColor(Color.WHITE)
            setPadding(dp(16), dp(8), dp(16), dp(8))
            background = glass(20, Color.parseColor("#33FFFFFF"))
        }
        root.addView(dateView, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.TOP or Gravity.START).apply {
            topMargin = statusH + dp(12); leftMargin = dp(16)
        })

        // Sağ üst: il (cam hap; uzun basınca il seçimi)
        cityView = TextView(this).apply {
            textSize = 15f
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            setTextColor(Color.WHITE)
            setPadding(dp(16), dp(8), dp(16), dp(8))
            background = glass(20, Color.parseColor("#33FFFFFF"))
            setOnLongClickListener { showCityPicker(); true }
        }
        root.addView(cityView, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.TOP or Gravity.END).apply {
            topMargin = statusH + dp(12); rightMargin = dp(16)
        })

        // Cam kart: [cami+hilal] | [vaktine / kalan süre / altın dalga]
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(18), dp(16), dp(18), dp(16))
            setBackgroundResource(R.drawable.glass_card)
            elevation = dp(6).toFloat()
        }
        card.addView(ImageView(this).apply {
            setImageResource(R.drawable.ic_mosque_moon)
            scaleType = ImageView.ScaleType.FIT_CENTER
        }, LinearLayout.LayoutParams(dp(84), dp(84)))
        card.addView(View(this).apply { setBackgroundColor(Color.parseColor("#40FFFFFF")) },
            LinearLayout.LayoutParams(dp(1), dp(84)).apply { setMargins(dp(14), 0, dp(14), 0) })

        val texts = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
        }
        labelView = TextView(this).apply {
            textSize = 20f
            typeface = Typeface.create("sans-serif-light", Typeface.NORMAL)
            setTextColor(soft)
            gravity = Gravity.CENTER
        }
        minutesView = TextView(this).apply {
            textSize = 56f
            typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            includeFontPadding = false
            setPadding(0, dp(2), 0, dp(4))
            shadow(this)
        }
        texts.addView(labelView)
        texts.addView(minutesView)
        texts.addView(ImageView(this).apply {
            setImageResource(R.drawable.ic_wave)
            scaleType = ImageView.ScaleType.FIT_CENTER
        }, LinearLayout.LayoutParams(dp(110), dp(14)))
        card.addView(texts, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))

        root.addView(card, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.TOP).apply {
            topMargin = statusH + (resources.displayMetrics.heightPixels * 0.11f).toInt()
            leftMargin = dp(16); rightMargin = dp(16)
        })

        // Alt bölüm: Güneş satırı + 5 vakit kutucuğu (her zaman görünür)
        val bottom = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
        }
        sunriseView = TextView(this).apply {
            textSize = 15f
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            setPadding(dp(16), dp(8), dp(16), dp(8))
            background = glass(20, Color.parseColor("#33FFFFFF"))
        }
        bottom.addView(sunriseView, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
            .apply { bottomMargin = dp(12) })

        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        for (i in shown.indices) {
            val box = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER_HORIZONTAL
                setPadding(dp(2), dp(12), dp(2), dp(12))
                setBackgroundResource(R.drawable.glass_tile)
            }
            box.addView(ImageView(this).apply {
                setImageResource(tileIcons[i])
                scaleType = ImageView.ScaleType.FIT_CENTER
            }, LinearLayout.LayoutParams(dp(30), dp(30)))
            val name = TextView(this).apply {
                text = names[shown[i]]
                textSize = 13f
                typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
                setTextColor(soft)
                gravity = Gravity.CENTER
                setPadding(0, dp(4), 0, dp(6))
                maxLines = 1
            }
            box.addView(name)
            box.addView(View(this).apply { setBackgroundColor(Color.parseColor("#33FFFFFF")) },
                LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(1)).apply {
                    setMargins(dp(10), 0, dp(10), dp(6))
                })
            val time = TextView(this).apply {
                textSize = 16f
                typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
                setTextColor(Color.WHITE)
                gravity = Gravity.CENTER
                maxLines = 1
            }
            box.addView(time)
            tileBoxes.add(box); tileNames.add(name); tileTimes.add(time)
            row.addView(box, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                .apply { setMargins(dp(4), 0, dp(4), 0) })
        }
        bottom.addView(row, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        bottom.addView(TextView(this).apply {
            text = "İli değiştirmek için il adına uzun basın"
            textSize = 15f
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            setPadding(dp(16), dp(8), dp(16), dp(8))
            background = glass(20, Color.parseColor("#33FFFFFF"))
        }, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
            .apply { topMargin = dp(12) })
        root.addView(bottom, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.BOTTOM).apply {
            leftMargin = dp(12); rightMargin = dp(12); bottomMargin = navH + dp(28)
        })

        setContentView(root)
        updateCityText()
        updateDate()
        loadTimes()
    }

    override fun onResume() {
        super.onResume()
        loadTimes()
        updateDate()
        handler.post(ticker)
    }

    override fun onPause() {
        super.onPause()
        handler.removeCallbacks(ticker)
        NamazWidget.refresh(applicationContext) // il değişmiş olabilir, widget'ı güncelle
    }

    private fun city() = prefs.getString("city", "İstanbul") ?: "İstanbul"

    private fun updateCityText() { cityView.text = "📍 " + city() }

    private fun updateDate() {
        dateView.text = "📅 " + SimpleDateFormat("d MMMM EEEE", Locale("tr", "TR")).format(Date())
    }

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
        // "19dk" veya "3sa 12dk"; saat varsa sığması için biraz küçülür
        minutesView.textSize = if (h > 0) 44f else 60f
        val sb = SpannableStringBuilder()
        fun part(n: Int, unit: String) {
            sb.append(n.toString())
            val start = sb.length
            sb.append(unit)
            sb.setSpan(RelativeSizeSpan(0.78f), start, sb.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        if (h > 0) { part(h, "sa"); sb.append(" ") }
        part(m, "dk")
        return sb
    }

    private fun refreshCountdown() {
        val t = times ?: return
        val now = System.currentTimeMillis()
        var next = t.indexOfFirst { at(it) > now }
        val target = if (next >= 0) at(t[next]) else { next = 0; at(t[0], 1) }
        val minutes = ((target - now + 59_999) / 60_000).toInt()

        minutesView.text = formatRemaining(minutes)
        labelView.text = "${names[next]} vaktine"
        sunriseView.text = "${names[1]}  ${t[1]}"
        for (i in shown.indices) {
            val k = shown[i]
            val active = k == next
            tileTimes[i].text = t[k]
            tileTimes[i].setTextColor(if (active) gold else Color.WHITE)
            tileNames[i].setTextColor(if (active) gold else soft)
            tileBoxes[i].setBackgroundResource(
                if (active) R.drawable.glass_tile_active else R.drawable.glass_tile)
        }
    }
}
