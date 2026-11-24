# Namaz Vakti

Bir sonraki namaz vaktine kalan dakikayı gösteren basit Android uygulaması.

- İl değiştirmek için sağ üstteki il adına uzun basın.
- Ana ekranda üstte cam efektli geri sayım kartı (örn. "Yatsı vaktine 19dk"), altta 5 vakit kutucuğu (İmsak, Öğle, İkindi, Akşam, Yatsı) her zaman görünür; sıradaki vakit altın çerçeveyle vurgulanır. Güneş vakti kartın altında küçük satır olarak gösterilir.

## Widget
Ana ekranda uzun basıp **Widget'lar → Namaz Vakti** seçin. Sıradaki vakte kalan süreyi (örn. "Akşam vaktine 3sa 12dk") saat ve dakika olarak gösterir (dakikada bir güncellenir); dokununca uygulama açılır. Widget 1x3 (1 hücre geniş, 3 hücre yüksek) boyutundadır: üstte küçük bir cam kartta sıradaki vaktin adı ve kalan süre, onun altında 5 vakit (ad üstte, saat altta) alt alta gösterilir; sıradaki vakit altın çerçeve ve sarı yazıyla vurgulanır. Tüm yazılar kalındır ve widget'ın gerçek ölçüsüne sığan en büyük boyutta hesaplanır (yeniden boyutlandırınca otomatik güncellenir).

İkinci bir **Namaz Vakti (2x2)** widget'ı da vardır: ortada en büyük kalın yazıyla şu anki saat, altında sıradaki vakte kalan süre (sa/dk) gösterilir; her dakika güncellenir ve yeniden boyutlandırınca yazılar otomatik büyür/küçülür. Widget listesinde iki widget da "Namaz Vakti" altında görünür (1x3 ve 2x2).

## GitHub'da derleme
Depoya push yapınca **Actions** sekmesinde "Android APK Derle" çalışır.
Bittiğinde çalıştırmanın altındaki **Artifacts → NamazVakti-debug-apk** dosyasını indirin.
