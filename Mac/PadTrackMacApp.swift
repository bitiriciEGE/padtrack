import SwiftUI

/// Menu bar only (LSUIElement): no Dock icon, no main window.
@main
struct PadTrackMacApp: App {
    @StateObject private var controller = AppController()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(controller)
        } label: {
            Image(systemName: controller.isConnected ? "hand.point.up.left.fill" : "hand.point.up.left")
        }
        .menuBarExtraStyle(.window)
    }
}
