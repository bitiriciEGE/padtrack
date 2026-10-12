import AppKit
import SwiftUI
import PadTrackCore

struct MenuContentView: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !controller.hasEventAccess { permissionCard }
            Divider()
            devices
            Divider()
            pointerSettings
            Divider()
            gestureSettings
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: controller.isConnected ? "hand.point.up.left.fill" : "hand.point.up.left")
                .font(.title2)
                .foregroundColor(controller.isConnected ? .accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("PadTrack").font(.headline)
                Text(controller.statusLine)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if controller.isConnected, let gesture = controller.snapshot.lastGesture {
                    Text("Son jest: \(gesture)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Erişilebilirlik izni gerekli", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundColor(.orange)
            Text("İmleci ve tıklamaları gönderebilmek için Sistem Ayarları › Gizlilik ve Güvenlik › Erişilebilirlik'te PadTrack'i açın.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Button("Ayarları aç") { controller.openAccessibilitySettings() }
                .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Cihazlar")
            if controller.snapshot.devices.isEmpty {
                Text("iPad'de PadTrack'i açın. USB kablo, aynı Wi‑Fi (ya da doğrudan Wi‑Fi) veya Bluetooth yeterli.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(controller.snapshot.devices) { device in
                    DeviceRow(device: device) { controller.connect(device.id) }
                }
            }
        }
    }

    private var pointerSettings: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("İmleç ve kaydırma")
            SliderRow(title: "İmleç hızı", value: $controller.settings.pointerSpeed, range: 0.3...3.0)
            SliderRow(title: "İvmelenme", value: $controller.settings.pointerAcceleration, range: 0...2)
            SliderRow(title: "Kaydırma hızı", value: $controller.settings.scrollSpeed, range: 0.3...3.0)
            Toggle("Doğal kaydırma", isOn: $controller.settings.naturalScrolling)
            Toggle("Kaydırma ataleti (momentum)", isOn: $controller.settings.momentumScrolling)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private var gestureSettings: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Jestler")
            Toggle("Dokunarak tıkla", isOn: $controller.settings.tapToClick)
            Toggle("İki parmakla dokun: sağ tık", isOn: $controller.settings.twoFingerSecondaryClick)
            Toggle("Dokun, tekrar dokun ve sürükle", isOn: $controller.settings.tapToDrag)
            Toggle("Üç parmakla sürükle", isOn: $controller.settings.threeFingerDrag)
            Toggle("3/4 parmak kaydır: Mission Control, Spaces", isOn: $controller.settings.swipeGestures)
            Toggle("Sıkıştırarak yakınlaştır (deneysel)", isOn: $controller.settings.pinchToZoom)
            Toggle("İki parmakla döndür (deneysel)", isOn: $controller.settings.rotate)
            Picker("Üç parmakla dokun", selection: $controller.settings.threeFingerTap) {
                ForEach(ThreeFingerTapAction.allCases, id: \.self) { action in
                    Text(action.title).tag(action)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private var footer: some View {
        HStack {
            Toggle("Otomatik bağlan", isOn: $controller.autoConnect)
                .toggleStyle(.checkbox)
            Spacer()
            if controller.isConnected {
                Button("Bağlantıyı kes") { controller.disconnect() }
            }
            Menu {
                Button("Ayarları sıfırla") { controller.resetSettings() }
                Button("Onaylı cihazları unut") { controller.forgetTrustedDevices() }
                Button("Erişilebilirlik ayarlarını aç") { controller.openAccessibilitySettings() }
                Divider()
                Button("PadTrack'ten çık") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .controlSize(.small)
    }
}

// MARK: - Pieces

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundColor(.secondary)
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack {
            Text(title)
                .frame(width: 96, alignment: .leading)
            Slider(value: $value, in: range)
            Text(String(format: "%.1f", value))
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 28, alignment: .trailing)
        }
    }
}

private struct DeviceRow: View {
    let device: CoreSnapshot.Device
    let connect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).lineLimit(1)
                Text(device.trusted ? device.transport.displayName : "\(device.transport.displayName) · ilk kez: onay gerekli")
                    .font(.caption2)
                    .foregroundColor(device.trusted ? .secondary : .orange)
            }
            Spacer()
            switch device.state {
            case .connected:
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            case .connecting:
                ProgressView().controlSize(.small)
            case .available:
                Button("Bağlan", action: connect).controlSize(.small)
            }
        }
    }

    private var icon: String {
        switch device.transport {
        case .usb: return "cable.connector"
        case .wifi: return "wifi"
        case .bluetooth: return "dot.radiowaves.left.and.right"
        }
    }
}

extension ThreeFingerTapAction {
    var title: String {
        switch self {
        case .off: return "Hiçbir şey"
        case .middleClick: return "Orta tık"
        case .lookUp: return "Sözlükte ara"
        }
    }
}
