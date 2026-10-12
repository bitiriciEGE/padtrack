import SwiftUI
import UIKit

@main
struct PadTrackApp: App {
    @StateObject private var host = PadHost()

    var body: some Scene {
        WindowGroup {
            TrackpadScreen()
                .environmentObject(host)
                .onAppear {
                    // A trackpad must never dim or lock while it is being used.
                    UIApplication.shared.isIdleTimerDisabled = true
                    host.start()
                }
        }
    }
}
