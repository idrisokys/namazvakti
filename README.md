# WebDAV Player

libmpv (media_kit) tabanli sade WebDAV video oynatici. macOS (Apple Silicon, 15+) ve Android (arm64, Android 10+).

- Oynat/duraklat, +-10 sn sarma, hiz, ses (masaustu)
- Kaldigin yerden devam
- Izlendi (yesil tik) / yarim kaldi (turuncu ilerleme) ikonlari

## Derleme
1. Bu klasoru GitHub reposuna yukle (main dalina push).
2. Actions sekmesinde "Build" calisir (veya "Run workflow").
3. Artifacts bolumunden APK ve macOS zip'ini indir.

Notlar:
- Android/macOS klasorleri CI'da `flutter create` ile uretilir, repoda tutulmaz.
- APK imzasiz-debug anahtariyla imzalanir; telefona "bilinmeyen kaynak" izniyle kurulur.
- macOS uygulamasi imzasizdir: ilk acilista sag tik > Ac, ya da `xattr -cr webdav_player.app`.
