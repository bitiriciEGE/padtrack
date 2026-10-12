iPad'i Mac'te trackpad olarak kullan. Bu sürüm **iPad'e uygulama kurmadan**, Safari üzerinden çalışır.

## Kurulum (Mac)

1. Aşağıdaki `PadTrack-…-macOS.zip` dosyasını indir, aç ve `PadTrack.app`'i **Uygulamalar** klasörüne taşı.
2. PadTrack'i aç. Uygulama henüz Apple Developer imzalı olmadığı için macOS açılışı engelleyip bir uyarı gösterir:
   **Sistem Ayarları › Gizlilik ve Güvenlik** sayfasının altındaki **Yine de Aç**'a tıkla ve onayla. Bu sadece ilk açılışta gerekir.
   (Terminal tercih edersen: `xattr -dr com.apple.quarantine /Applications/PadTrack.app`)
3. **Erişilebilirlik** iznini ver: Sistem Ayarları › Gizlilik ve Güvenlik › Erişilebilirlik › PadTrack açık. Bu izin olmadan imleç hareket etmez.

## Bağlanma (iPad)

1. Mac ve iPad aynı Wi‑Fi'de olsun.
2. Mac'te menü çubuğundaki el simgesi › **Safari ile bağlan** › QR kodu iPad'in Kamerası ile okut, Safari'de aç.
3. Safari'de **Paylaş › Ana Ekrana Ekle**: sonraki seferlerde PadTrack simgesine dokunman yeterli.

QR kod tek kullanımlıktır; kullanılınca Mac yeni bir kod üretir. Eşleşmiş bir iPad'i silmek için Mac menüsünde "…" › **Onaylı cihazları unut**.

## Bilinen sınırlar

- Yalnızca Wi‑Fi (USB/Bluetooth için iPad uygulaması gerekir). Gecikme yerel uygulamadan biraz yüksek.
- Bazı kampüs/misafir ağları (ör. eduroam) cihazlar arası trafiği engeller; `.local` adı açılmazsa menüden **IP adresi**'ni seç.
- Her güncellemeden sonra Erişilebilirlik listesinde PadTrack'i kaldırıp yeniden eklemen gerekebilir (imzasız uygulamalarda macOS izni sürüme bağlar).
