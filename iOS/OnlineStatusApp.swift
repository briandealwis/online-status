import OnlineStatusCore
import SwiftUI

/// The iPhone app: probes only while it's open. iOS suspends it in the background,
/// so it pauses there and judges afresh when it comes back.
@main
struct OnlineStatusApp: App {
    @StateObject private var monitor = ConnectivityMonitor()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            StatusScreen(monitor: monitor)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                monitor.resume()
            case .background:
                monitor.pause()
            default:
                break
            }
        }
    }
}
