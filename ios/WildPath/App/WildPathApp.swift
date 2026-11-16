import SwiftUI

@main
struct WildPathApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        GoogleMapsConfig.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            LocationProvider.shared.setPhoneActive(phase == .active)
            if phase == .active {
                Task { await Uploader.shared.uploadPending() }
            }
        }
    }
}
