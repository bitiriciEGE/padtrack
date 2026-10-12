# PadTrack — iPad'i Mac'te Magic Trackpad olarak kullan

iPad ekranına dokunduğun her şey Mac'te gerçek bir trackpad gibi davranır: imleç, dokunarak tıklama, iki parmakla sağ tık, iki parmakla pürüzsüz kaydırma (momentumlu), sıkıştırarak yakınlaştırma, 3/4 parmakla Mission Control ve Spaces geçişi.

İki şekilde kullanılır:

- **Ücretsiz sürüm (Safari):** iPad'e hiçbir şey kurulmaz. Mac uygulaması yerel bir web sayfası sunar, iPad bu sayfayı Safari'de açar (QR kodla eşleşir, Ana Ekrana eklenir). Sadece Wi‑Fi. → [Ücretsiz sürüm: Safari ile](#ücretsiz-sürüm-safari-ile)
- **iPad uygulaması:** Xcode ile iPad'e kurulur (ileride TestFlight/App Store). USB, Wi‑Fi ve Bluetooth; en düşük gecikme.

Bağlantı şu yollardan biriyle kurulur, en hızlısı otomatik seçilir:

| Yol | Nasıl çalışır | Beklenen gecikme* |
|---|---|---|
| **USB kablo** | Mac'teki `usbmuxd` (Xcode/Finder'ın iPad'le konuştuğu servis) üzerinden TCP tüneli. Ağ gerekmez. | birkaç ms |
| **Wi‑Fi / IP** | Bonjour ile bulunur, UDP ile gönderilir. Aynı ağda olmasanız bile Apple'ın doğrudan Wi‑Fi'si (AirDrop'un kullandığı) devreye girer. | ~5–15 ms |
| **Safari (web)** | iPad Safari'de Mac'in sunduğu sayfayı açar, dokunuşları WebSocket (TCP) ile yollar. Uygulama gerekmez; aynı Wi‑Fi şart. | Wi‑Fi'den biraz fazla |
| **Bluetooth LE** | iPad bir BLE servisi yayınlar, Mac abone olur. Hiçbir ağ yokken yedek. | ~15–40 ms |

\*Ölçüm değil, bu taşıma yöntemlerinin tipik değerleri. Gerçek değeri Mac menüsünde "~X ms" olarak görürsün (ping süresinin yarısı).

---

## Mimari

```
 iPad (PadTrack)                                   Mac (PadTrack menü çubuğu)
 ┌──────────────────────────┐                      ┌─────────────────────────────────┐
 │ TouchSurfaceView         │  dokunuş karesi      │ TrackpadCore (tek seri kuyruk)  │
 │  tüm parmaklar, 120 Hz   │ ───────────────────▶ │  ├─ GestureEngine (PadTrackCore)│
 │ PadHost                  │  USB / UDP / BLE     │  │   kare → tık/kaydır/jest     │
 │  ├─ NetworkServer        │                      │  └─ EventInjector               │
 │  │   UDP+Bonjour, TCP    │ ◀─────────────────── │      CGEvent → macOS            │
 │  └─ BLEPeripheral        │  subscribe / ping    │ USB · Bonjour · BLE keşfi       │
 └──────────────────────────┘                      └─────────────────────────────────┘
```

Temel karar: **iPad ham dokunuşları gönderir, jestleri Mac tanır.** Her mesaj o anda ekrandaki *bütün* parmakların tam listesidir (bir "kare"). Bu yüzden:

- UDP'de bir paket kaybolursa bir sonraki kare her şeyi düzeltir; "takılı kalmış parmak" olmaz.
- Bluetooth sıkışırsa ara hareket kareleri birleştirilir, ama parmak *indi/kalktı* kareleri asla atılmaz (tıklamalar kaybolmaz).
- Zamanlamalar (dokunma süresi, hız, momentum) iPad'in kendi saat damgalarıyla hesaplanır; ağdaki gecikme dalgalanması jestleri bozmaz.
- Tüm ayarlar Mac'tedir; iPad uygulaması basit kalır.
- Safari sürümü aynı protokolü konuşur: sayfa aynı ikili mesajları WebSocket üzerinden gönderir, Mac'te aynı çekirdeğe ve jest motoruna gider. Mac için sadece yeni bir bağlantı türüdür (`WebLink`).

Klasörler:

```
Packages/PadTrackCore/   Ortak Swift paketi
  Sources/PadTrackCore/    protokol (Wire.swift), jest motoru, ayarlar, HTTP/WebSocket ayrıştırıcı
  Sources/PadTrackWeb/     Mac'in web sunucusu (Network.framework) ve QR eşleştirme
iPad/                    iPad uygulaması (SwiftUI + UIKit dokunma yüzeyi)
Mac/                     Menü çubuğu uygulaması (bağlantılar, olay enjeksiyonu, arayüz)
WebClient/               iPad Safari sayfası (HTML/JS); Mac uygulamasının içine kopyalanır
WebClientTests/          Sayfanın protokol ve bağlantı mantığı testleri (Node)
project.yml              XcodeGen tanımı → PadTrack.xcodeproj üretir
```

---

## Kurulum

Gerekenler: Xcode 15 veya üstü, macOS 13+, iPadOS 16+, Homebrew.

1. Projeyi üret ve aç:
   ```bash
   cd PadTrack
   make open          # XcodeGen yoksa kurar, PadTrack.xcodeproj'u üretip açar
   ```
2. Xcode'da **her iki hedef** (`PadTrack-iPad`, `PadTrack-Mac`) için *Signing & Capabilities › Team* olarak Apple ID'ni seç. Ücretsiz Apple ID yeter (iPad'deki imza 7 günde bir yenilenir: tekrar Run etmek yeterli). Kalıcı olsun istersen Team ID'yi `project.yml` içindeki `DEVELOPMENT_TEAM` satırına yaz.
   - Xcode "bundle identifier kullanılamıyor" derse `project.yml`'deki `io.github.padtrack` önekini kendine özgü bir şeyle değiştir ve `make project` çalıştır.
3. **Mac uygulaması:** şemayı `PadTrack-Mac` seçip Run. Menü çubuğunda el simgesi belirir.
   - İlk açılışta **Erişilebilirlik** izni ister (Sistem Ayarları › Gizlilik ve Güvenlik › Erişilebilirlik › PadTrack açık). Bu izin olmadan macOS sahte imleç olaylarını kabul etmez.
   - Yerel Ağ ve Bluetooth izinlerine de "İzin Ver" de.
4. **iPad uygulaması:** iPad'i kabloyla tak, Xcode'da hedef cihaz olarak iPad'i seç, şemayı `PadTrack-iPad` yapıp Run.
   - iPad'de ilk seferde: *Ayarlar › Gizlilik ve Güvenlik › Geliştirici Modu* açık olmalı; "Bu bilgisayara güven" sorusuna Güven de.
   - Uygulama Yerel Ağ ve Bluetooth izni ister, ikisine de izin ver.
5. İki uygulama da açıkken kablo bağlantısı kendiliğinden kurulur; iPad'in üstünde "MacBook · USB" gibi bir yazı görürsün.
   **Wi‑Fi ve Bluetooth'ta ilk sefer** Mac menüsünde cihazın yanındaki **Bağlan**'a tıkla. Mac o iPad'i hatırlar, sonraki seferlerde kendisi bağlanır. Bir kez kabloyla bağlanmış iPad de otomatik olarak onaylı sayılır.

### Neden onay?
iPad'den gelen dokunuşlar Mac'inde her yere tıklayabilir. Mac aynı ağda `_padtrack` yayınlayan *her* cihaza kendiliğinden bağlansaydı, örneğin kampüs Wi‑Fi'sindeki biri Mac'ini kontrol edebilirdi. Bu yüzden:
- USB her zaman güvenilir (fiziksel kablo + iPad'in "Bu bilgisayara güven" onayı).
- Wi‑Fi/Bluetooth cihazı yalnızca senin onayladığın kalıcı cihaz kimliğiyle otomatik bağlanır; dokunuşlar sadece bu onaylı bağlantıdan kabul edilir.
- Menüdeki "…" › **Onaylı cihazları unut** listeyi sıfırlar.

Testler (jest motoru, protokol, web sunucusu, Safari sayfası): `make test`

---

## Ücretsiz sürüm: Safari ile

iPad'e uygulama kurmadan, Xcode olmadan çalışır.

**Mac:**
1. [Releases](../../releases) sayfasından `PadTrack-…-macOS.zip`'i indir, aç, `PadTrack.app`'i Uygulamalar'a taşı.
2. İlk açılışta macOS uygulamayı engeller (henüz Apple Developer imzalı değil): **Sistem Ayarları › Gizlilik ve Güvenlik** sayfasının altındaki **Yine de Aç**'a tıkla. Terminal ile: `xattr -dr com.apple.quarantine /Applications/PadTrack.app`
3. **Erişilebilirlik** iznini ver (yukarıdaki Kurulum 3. adım).

**iPad:**
1. Mac ile aynı Wi‑Fi'ye bağlan.
2. Mac menüsünde **Safari ile bağlan › iPad'i eşleştir (QR kod)**: QR kodu iPad'in Kamerası ile okut, Safari'de aç.
3. Safari'de **Paylaş › Ana Ekrana Ekle**. Sonraki seferlerde simgeye dokunman yeter; sayfa tam ekran açılır ve Mac'e kendiliğinden bağlanır.

Adres: Mac `http://<Mac-adı>.local:47391` adresinde yayın yapar. `.local` adı bazı kampüs/misafir ağlarında çözülmez; menüde **IP adresi**'ni seçip QR'ı onunla okut (IP değişirse yeniden okutman gerekir).

### Safari'de güvenlik
Aynı Wi‑Fi'deki herkes 47391 portuna ulaşabilir, bu yüzden:
- Sayfayı açmak serbesttir ama **dokunuş göndermek için kimlik gerekir**: ilk seferde QR koddaki tek kullanımlık anahtar, sonra Mac'in o iPad'e verdiği uzun rastgele cihaz belirteci. Anahtarsız/belirteçsiz bağlantı 10 saniye içinde kapatılır.
- QR anahtarı URL'nin `#` kısmındadır: Safari onu hiçbir isteğe koymaz, sayfa okuyup WebSocket üzerinden gösterir. Bir kez kullanılınca Mac yeni anahtar üretir; menüdeki **Yeni kod** da eskisini geçersiz kılar.
- Mac belirteçlerin kendisini değil SHA-256 özetini saklar. **Onaylı cihazları unut** tüm Safari eşleşmelerini de siler ve açık sayfaları kapatır.
- Başka bir siteden açılan sayfalar (farklı `Origin`) WebSocket'e bağlanamaz.
- Trafik şifresiz `http`/`ws`'dir (yerel ağda geçerli sertifika yok): aynı ağda trafiği dinleyen biri belirteci görebilir. Güvenmediğin açık ağlarda kullanma; menüden **Safari ile bağlan**'ı kapatınca sunucu tamamen durur.

---

## Jestler

| iPad'de | Mac'te |
|---|---|
| Tek parmakla kaydır | İmleç (hıza göre ivmelenir) |
| Tek parmakla dokun | Sol tık · iki kez = çift tık · üç kez = üçlü tık |
| Dokun, hemen tekrar dokun ve kaydır | Sürükle-bırak |
| Dokun, tekrar dokun ve parmağı kaldırma; başka bir parmakla kaydır | Pencere/dosya sürükleme: ilk parmak basılı tuş gibi kalır, ikinci parmak taşır |
| İki parmakla dokun | Sağ tık |
| İki parmakla kaydır | Kaydırma (gerçek trackpad gibi piksel hassasiyetinde, fazlı ve momentumlu) |
| İki parmağı aç/kapat | Yakınlaştır/uzaklaştır *(deneysel)* |
| İki parmakla çevir | Döndür *(deneysel, varsayılan kapalı)* |
| Üç parmakla dokun | Orta tık (menüden "Sözlükte ara" yapılabilir) |
| 3 veya 4 parmakla yukarı | Mission Control |
| 3 veya 4 parmakla aşağı | Uygulama pencereleri (App Exposé) |
| 3 veya 4 parmakla sola/sağa | Sağdaki/soldaki masaüstüne (Space) geç |
| Üç parmakla sürükle *(menüden açılır)* | Pencere/dosya sürükleme; açıkken 3 parmak kaydırma yerine sadece 4 parmak çalışır |

Hız, ivme, kaydırma hızı, doğal kaydırma ve her jest Mac menüsünden ayarlanır; ayarlar kaydedilir.

---

## iPad'de önerilen ayarlar

- **Ayarlar › Çoklu Görev ve Jestler › Jestler: kapalı.** Yoksa 4–5 parmak hareketleri iPad'in kendi ana ekran/uygulama değiştirme jestlerini tetikler.
- Ekran kenarından kaydırmalar (Ana Ekran, Denetim Merkezi) PadTrack açıkken iki kez kaydırma ister. Tamamen kilitlemek için **Rehberli Erişim** (Ayarlar › Erişilebilirlik) kullan.
- Ekran PadTrack açıkken kapanmaz.

---

## Sorun giderme

| Belirti | Neden / çözüm |
|---|---|
| Bağlı görünüyor ama imleç oynamıyor | Erişilebilirlik izni yok. Xcode'dan her yeniden derlemede imza değişebilir; Erişilebilirlik listesinden PadTrack'i **sil (−) ve tekrar ekle**. Team seçmek bunu büyük ölçüde önler. |
| Tek parmakla dokunmak sağ tık gibi davranıyor | Eski sürümde masaüstü değiştirme jesti Control tuşunu "basılı" bırakabiliyordu (Control+tık = sağ tık). Güncel sürümde düzeltildi; hemen geçmesi için Mac klavyesinde Control'e bir kez bas. Menüdeki "Son jest" satırı "Sağ tık" diyorsa iPad iki parmak görüyor demektir: ekranda ikinci bir parmak izi (halka) var mı bak. |
| USB görünüyor, "iPad'de PadTrack açık değil" diyor | iPad uygulaması ön planda olmalı. Kablodaki iPhone'lar da listelenir; uygulama yüklü değilse otomatik atlanır. |
| Wi‑Fi'de cihaz hiç görünmüyor | Mac: Sistem Ayarları › Gizlilik ve Güvenlik › Yerel Ağ › PadTrack açık mı? iPad: Ayarlar › PadTrack › Yerel Ağ. Misafir/kurumsal ağlar (ör. eduroam) cihazlar arası trafiği engelleyebilir; o durumda USB kabloyu kullan ya da iki cihazda da Wi‑Fi açıkken ağdan çıkmayı dene (doğrudan Wi‑Fi devreye girebilir). |
| Masaüstü (Space) geçişi çalışmıyor | Sistem Ayarları › Klavye › Klavye Kısayolları › Mission Control'de "Sola/Sağa bir alan taşı" (⌃← / ⌃→) açık olmalı. |
| Yakınlaştırma bazı uygulamalarda çalışmıyor | macOS'te sahte pinch için resmi API yok; PadTrack belgelenmemiş olay alanlarını kullanır. Desteklemeyen uygulamada menüden kapat. |
| Bağlantı sürekli Bluetooth'ta kalıyor | Wi‑Fi'yi veya kabloyu kontrol et; daha hızlı yol bulunduğu anda kendiliğinden geçer. Elle seçilen cihaza (Bağlan) sabitlenir, otomatik yükseltme yapılmaz. |
| Safari: sayfa açılmıyor | Mac menüsünde **Safari ile bağlan** açık ve hata yazmıyor mu? Aynı Wi‑Fi'de misiniz? `.local` adresi açılmıyorsa menüden **IP adresi**'ni seç. macOS Güvenlik Duvarı açıksa PadTrack için "gelen bağlantılara izin ver"i onayla. |
| Safari: "Eşleştirme gerekli" | QR kod kullanılmış veya yenilenmiş olabilir: menüdeki güncel kodu okut. Ana Ekran simgesinden açıyorsan ve eşleşme Mac'te silindiyse, QR'ı okut ve açılan sayfayı Ana Ekrana yeniden ekle. |
| Safari: "Mac menüsünde Bağlan'a tıkla" yazıyor | Sayfa eşleşmiş ama Mac onu seçmemiş: menüde **Otomatik bağlan** kapalı ya da "Bağlantıyı kes"e basılmış. Cihazın yanındaki **Bağlan**'a tıkla. |
| Safari: ekran kapanıyor | Safari yerel `http` adreslerinde ekranı açık tutamıyor. iPad'de Ayarlar › Ekran ve Parlaklık › Otomatik Kilit süresini uzat. |

---

## Sınırlar (dürüst liste)

- iPad'de fiziksel "bas-tık" ve Force Touch yok: tıklamalar dokunarak yapılır, titreşim geri bildirimi yok.
- Pinch/rotate ve Mission Control/App Exposé tetikleme yöntemleri Apple'ın belgelenmemiş arayüzleridir; bir macOS güncellemesi bozabilir. Bozulursa Mission Control otomatik olarak ⌃↑/⌃↓ kısayoluna düşer.
- Mac uygulaması sandbox dışında çalışır (imleç olayı göndermek ve USB tüneli için zorunlu), bu yüzden Mac App Store'a uygun değildir; kişisel kullanım içindir.
- Birden fazla iPad varsa ve otomatik bağlanma açıksa, kablo takılı cihaz önceliklidir.
- Trafik şifrelenmez ve cihaz kimliği gizli bir anahtar değildir: aynı ağda trafiği dinleyip kimliği taklit eden kararlı bir saldırgana karşı koruma sağlamaz. Güvenmediğin açık ağlarda USB kullan veya otomatik bağlanmayı kapat.
- Safari sürümü: sadece Wi‑Fi; TCP olduğu için kayıplı ağda gecikme uygulamadan daha dalgalı olabilir; Safari'de kenar kaydırmaları ve 4–5 parmak jestleri araya girebilir (Ana Ekrandan açmak ve iPad'in Jestler ayarını kapatmak çoğunu çözer); sayfa arka plana geçince bağlantı kapanır, öne gelince kendiliğinden döner.
- GitHub Releases'taki Mac uygulaması Apple imzalı/onaylı (notarize) değildir: ilk açılışta "Yine de Aç" gerekir ve her güncellemeden sonra Erişilebilirlik iznini yenilemek gerekebilir.

---

## Protokol özeti

Tüm sayılar little-endian. USB'de (TCP) her mesajın önünde 2 baytlık uzunluk vardır; UDP ve Bluetooth'ta her paket tek mesajdır.

| Tür | Yön | İçerik |
|---|---|---|
| `1 hello` | iPad → Mac | sürüm, yüzey genişliği/yüksekliği (pt), cihaz adı, kalıcı cihaz kimliği |
| `2 frame` | iPad → Mac | sıra no (u32), zaman (f64, sn), parmak sayısı, her parmak için id (u8) + x, y (f32, pt) |
| `3 ping` / `4 pong` | Mac ↔ iPad | Mac saati (ns); gecikme ölçümü ve canlılık |
| `5 subscribe` | Mac → iPad | sürüm, taşıma türü, Mac adı — "dokunuşları bu bağlantıdan bana gönder" |
| `6 bye` | iki yön | bağlantıyı kapat |

Beş parmaklı bir kare 59 bayttır; 120 Hz'de ~7 KB/s.

**Safari:** sayfa `ws://<mac>:47391/ws` adresine bağlanır. İlk mesaj JSON metindir: `{"type":"pair","key":…}` (QR) veya `{"type":"resume","token":…}`; Mac `{"type":"welcome",…}` (eşleştirmede yeni `token` ile) ya da `{"type":"denied"}` + kapatma (kod 4001) ile cevap verir. Sonrasında her ikili WebSocket mesajı yukarıdaki tablodan tek bir mesajdır (uzunluk öneki yok). Taşıma türü `4 = web`.
