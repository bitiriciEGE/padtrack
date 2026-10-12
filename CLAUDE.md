# CLAUDE.md: PadTrack proje bağlamı

Bu dosya her Claude Code oturumunda otomatik okunur. Kullanıcıyla (Ege) **Türkçe** konuş; commit mesajları İngilizce.


Son güncelleme: 2026-10-12

## Proje nedir
iPad'i Mac'te Magic Trackpad olarak kullandıran uygulama. İki parça:
- **Mac menü çubuğu uygulaması:** dokunuşları alır, jest motoruyla (PadTrackCore) tık/kaydırma/pinch/Mission Control'e çevirir, CGEvent ile macOS'a gönderir. Erişilebilirlik izni gerekir.
- **iPad tarafı:** dokunuşları gönderir.

Kaynak kod: **https://github.com/bitiriciEGE/padtrack** (bu depo) (Public, lisans yok = tüm hakları saklı).

## Dallar (iki versiyon)
| Dal | Versiyon | Durum |
|---|---|---|
| `main` | **Yerel iPad uygulaması** (USB/usbmuxd + Wi‑Fi Bonjour/UDP + Bluetooth LE). Apple Developer Program (99 $/yıl) alındığında TestFlight/App Store'a gidecek versiyon. | Çalışıyor; Ege kendi iPad + MacBook Air'inde test etti. |
| `web-client` | **Ücretsiz dağıtım versiyonu:** Mac uygulaması yerel web sunucusu açar, iPad Safari'den (Ana Ekrana Ekle) bağlanır. App Store/Xcode gerektirmez. | Henüz başlanmadı, dal `main`'den ayrıldı. |

## web-client için plan (kararlaştırılan)
1. Mac uygulamasına yerel HTTP + WebSocket sunucusu (Network.framework); Bonjour ile `mac-adı.local`.
2. iPad için tek sayfalık dokunma yüzeyi (HTML/JS, multi-touch), mevcut ikili protokolün aynısını WebSocket üzerinden gönderir; jest motoru değişmez.
3. **Güvenlik:** Mac menüsünde QR kod + tek kullanımlık eşleştirme anahtarı; anahtarsız bağlantı reddedilir (kampüs/kafe Wi‑Fi'si nedeniyle zorunlu).
4. Mac menüsünde adres + QR kod.
5. GitHub Actions: her güncellemede Mac .app derleyip GitHub Releases'a koy (imzasız; kullanıcı "Yine de Aç" ile açar, README'de anlatılacak).
Sınırlar: sadece Wi‑Fi, gecikme biraz daha yüksek, Safari kenar jestleri.

## Çalışan özellikler (main)
- İmleç (ivmeli), dokun = tık, çift/üçlü tık, iki parmak dokun = sağ tık, üç parmak = orta tık / sözlük
- İki parmak kaydırma (piksel hassas, fazlı, momentum), pinch (deneysel, belgelenmemiş CGEvent alanları), döndürme (kapalı)
- 3/4 parmak: Mission Control, App Exposé, Spaces
- Dokun + tekrar dokun ve tut → sürükle; tutan parmak basılıyken **başka parmakla** sürükleme (Ege'nin istediği Magic Trackpad davranışı)
- Bağlantı önceliği USB > Wi‑Fi > Bluetooth, otomatik yükseltme
- Güven modeli: USB her zaman; Wi‑Fi/BLE ilk seferde menüden "Bağlan" ile onay, kalıcı cihaz kimliğiyle hatırlanır
- Menüde "Son jest" teşhis satırı

## Çözülen hatalar (tekrarlanmasın)
- **Tık → sağ tık:** Spaces kısayolu Control'ü basılı bırakıyordu. Çözüm: kısayollar özel CGEventSource ile tam basma/bırakma; fare olaylarına `flags` açıkça yazılıyor.
- İlk "hareketsiz bekle + ikinci parmak" denemesi yanlış anlaşılmıştı, geri alındı; doğrusu "dokun, tekrar dokun ve tut" ile başlayan iki parmak sürükleme.

## Kurulum / çalışma ortamı
- Ege MacBook Air (Apple Silicon) kullanıyor; Xcode, Homebrew, XcodeGen, GitHub CLI (`gh`, giriş yapılmış) kurulu.
- Proje: `make open` (XcodeGen ile .xcodeproj üretir). Şemalar: `PadTrack-Mac`, `PadTrack-iPad`.
- Ücretsiz Apple ID (Personal Team): iPad imzası 7 günde bir yenileniyor.
- Mac uygulaması Archive › Copy App ile Uygulamalar'a kopyalandı, Giriş Öğeleri'nde.

## GitHub / iş akışı notları
- Claude GitHub App hesapta **All repositories** ile kurulu: bulut oturumları mevcut depolara push edebilir.
- **Yeni depo oluşturma** sadece Mac'teki yerel oturumdan (`gh`) yapılabilir; bulut oturumunda Ege depoyu github.com/new'den açar.
- `.gitignore` imza dosyalarını (p12, mobileprovision, AuthKey .p8, .env) ve XcodeGen çıktılarını hariç tutar.

## Yayın yol haritası
1. (web-client) Ücretsiz versiyon + GitHub Releases + demo videosu + tanıtım sayfası
2. Reddit (r/macapps, r/ipad, r/SideProject), Show HN → geri bildirim
3. İlgi olursa: Developer Program (99 $) → iPad TestFlight, Mac notarize .dmg → Product Hunt → App Store
Bekleyen hazırlıklar: uygulama ikonu, Hardened Runtime (notarize için), izinleri anlatan ilk açılış ekranı.

## Çalışma kuralları
- Hangi daldasın kontrol et: `main` = yerel iPad uygulaması, `web-client` = ücretsiz web versiyonu.
- Jest motoru (`Packages/PadTrackCore`) iki dalda ortak; motor düzeltmelerini `main`'e yap, sonra `web-client`'e merge et.
- Bu ortamda Swift derleyicisi olmayabilir; değişiklikten sonra Ege'den Xcode'da derleyip denemesini iste, hata çıktısını yapıştırmasını söyle.
- Push öncesi gizli bilgi taraması yap (anahtar, token, sertifika, kişisel bilgi). Depo herkese açık.
- Değişiklik ve kararlar oldukça bu dosyayı güncelle.
