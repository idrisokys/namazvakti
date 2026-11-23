# WebDAV Player

libmpv (media_kit) tabanli sade WebDAV video oynatici.
macOS (Apple Silicon, 15+), Android 10+ (arm64 + armv7), Android TV.

- Sunucu sabit: `http://192.168.1.44:8080/` (lib/main.dart icinde `_serverUrl`)
- Acilis ekrani: Izleme Listem. Sag alttaki "Listeme ekle" ile sunucudan klasor/video ekle
- Ekleme ekraninda "Tumunu sec" veya tek tek secim; secilenleri listeye ya da yeni klasore ekle
- Izleme listesinde klasor olusturma, yeniden adlandirma, silme, ogeleri klasore tasima
- Oynat/duraklat, +-10 sn sarma, hiz; kaldigin yerden devam; izlendi (yesil tik) / yarim (turuncu ilerleme)
- TV uzaktan kumanda: OK oynat/duraklat, sol/sag +-10 sn, yukari/asagi hiz
- Yatay ekran desteklenir (oynatici yatay acilir)

## Derleme
1. Zip'i bilgisayarda ac, icindekileri (lib, pubspec.yaml, .gitignore, README.md, .github) repo kokune koy, main dalina push et.
2. Actions > "Build" (gerekirse "Run workflow").
3. Artifacts: `webdav-player-android` (arm64-v8a ve armeabi-v7a APK) ve macOS zip.

Notlar:
- Android/macOS klasorleri CI'da `flutter create` ile uretilir.
- APK debug anahtariyla imzalanir; "bilinmeyen kaynak" izniyle kurulur.
- macOS uygulamasi imzasizdir: ilk acilista sag tik > Ac, ya da `xattr -cr webdav_player.app`.
