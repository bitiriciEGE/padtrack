import SwiftUI

struct TrackpadScreen: View {
    @EnvironmentObject private var host: PadHost
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false

    var body: some View {
        ZStack(alignment: .top) {
            TouchSurface(
                showTouches: host.showTouches,
                onFrame: { touches, timestamp, structural in
                    host.handleTouches(touches, timestamp: timestamp, structural: structural)
                },
                onResize: { size in
                    host.updateSurfaceSize(size)
                }
            )
            .ignoresSafeArea()

            HStack(alignment: .top) {
                StatusPill(text: host.statusText, connected: host.isConnected)
                    .allowsHitTesting(false)
                Spacer()
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.title3)
                        .foregroundColor(Color.white.opacity(0.3))
                        .padding(12)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
        .background(Color(red: 0.07, green: 0.07, blue: 0.08).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        // Edge swipes (Home, Control Center) need a second swipe while PadTrack is open.
        .defersSystemGestures(on: .all)
        .sheet(isPresented: $showSettings) {
            PadSettingsView().environmentObject(host)
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { host.start() }
        }
    }
}

struct StatusPill: View {
    let text: String
    let connected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(connected ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.footnote.weight(.medium))
                .foregroundColor(Color.white.opacity(0.55))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }
}

struct PadSettingsView: View {
    @EnvironmentObject private var host: PadHost
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Bağlantı") {
                    LabeledContent("Durum", value: host.statusText)
                    LabeledContent("Wi‑Fi", value: host.wifiStatus)
                    LabeledContent("USB", value: host.usbStatus)
                    Toggle("Bluetooth ile bağlanmaya izin ver", isOn: $host.bluetoothEnabled)
                    if host.bluetoothEnabled {
                        LabeledContent("Bluetooth", value: host.bluetoothStatus)
                    }
                }
                Section("Görünüm") {
                    Toggle("Parmakları göster", isOn: $host.showTouches)
                }
                Section("İpuçları") {
                    Text("Mac'te PadTrack menü çubuğu uygulaması açık olmalı. Kablo takılıysa USB, değilse aynı Wi‑Fi ya da doğrudan Wi‑Fi, o da yoksa Bluetooth otomatik seçilir.")
                    Text("4–5 parmak jestlerinin iPad'in kendi jestleriyle çakışmaması için Ayarlar › Çoklu Görev ve Jestler'de \"Jestler\"i kapatın.")
                    Text("Ekran kenarından kaydırmalar PadTrack açıkken iki kez kaydırma ister; tam kilit için Rehberli Erişim kullanılabilir.")
                }
                .font(.footnote)
                .foregroundColor(.secondary)
            }
            .navigationTitle("PadTrack")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bitti") { dismiss() }
                }
            }
        }
    }
}
