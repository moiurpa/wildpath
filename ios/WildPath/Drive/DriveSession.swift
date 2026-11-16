import Foundation
import Combine
import CoreLocation
import UIKit
import UserNotifications

/// Everything that happens during a drive: following the car, warnings for
/// hotspots ahead, fetching nearby reports, and the optional camera.
@MainActor
final class DriveSession: ObservableObject {
    static let shared = DriveSession()

    @Published private(set) var isDriving = false
    @Published var followCar = true
    @Published private(set) var location: CLLocation?
    @Published private(set) var warning: HotspotWarning?
    @Published private(set) var nearbyPins: [ServerClient.Pin] = []
    @Published private(set) var communityHotspots: [ServerClient.CommunityHotspot] = []
    @Published private(set) var toast: String?
    @Published private(set) var period: RiskModel.Period = .day
    @Published private(set) var month = SunClock.month()

    let camera = CameraDetectionService()

    private let warner = HotspotWarner()
    private var cancellables = Set<AnyCancellable>()
    private var lastWarningCheck = Date.distantPast
    private var lastFetchLocation: CLLocation?
    private var lastFetchAt = Date.distantPast
    private var toastTask: Task<Void, Never>?
    private var warningTask: Task<Void, Never>?

    private init() {
        LocationProvider.shared.$lastLocation
            .compactMap { $0 }
            .sink { [weak self] loc in self?.handle(loc) }
            .store(in: &cancellables)
    }

    // MARK: Drive on / off

    func startDrive() {
        guard !isDriving else { return }
        isDriving = true
        followCar = true
        LocationProvider.shared.setDriving(true)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        UIApplication.shared.isIdleTimerDisabled = true
        Speaker.shared.say("Drive started. I'll warn you about wildlife ahead.")
        if camera.isConsented && camera.wantsToRun { camera.start() }
    }

    func endDrive() {
        guard isDriving else { return }
        isDriving = false
        camera.stop()
        LocationProvider.shared.setDriving(false)
        UIApplication.shared.isIdleTimerDisabled = false
        warning = nil
        Task { await Uploader.shared.uploadPending() }
    }

    // MARK: Reporting from the driving screen

    func report(_ species: Species) {
        Task {
            let outcome = await ReportService.shared.report(species, source: .phone)
            switch outcome {
            case .saved:
                showToast("\(species.displayName) reported. Thank you.")
                Speaker.shared.say("\(species.displayName) reported.")
            case .duplicate:
                showToast("Already reported.")
            case .failed(let reason):
                showToast(reason)
            }
        }
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { self.toast = nil }
        }
    }

    // MARK: Location updates

    private func handle(_ loc: CLLocation) {
        location = loc
        camera.currentSpeed = max(loc.speed, 0)
        guard isDriving else { return }

        let now = Date()
        if now.timeIntervalSince(lastWarningCheck) >= 2 {
            lastWarningCheck = now
            period = SunClock.period(at: loc.coordinate, date: now)
            month = SunClock.month(now)
            if let w = warner.evaluate(loc, community: communityHotspots, now: now) {
                announce(w)
            }
        }

        let movedFar = lastFetchLocation.map { loc.distance(from: $0) > 5000 } ?? true
        if movedFar || now.timeIntervalSince(lastFetchAt) > 120 {
            lastFetchLocation = loc
            lastFetchAt = now
            Task { await refreshCommunityData(around: loc.coordinate) }
        }
    }

    private func announce(_ w: HotspotWarning) {
        warning = w
        Speaker.shared.say(w.spoken)
        if UIApplication.shared.applicationState != .active {
            let content = UNMutableNotificationContent()
            content.title = w.title
            content.body = w.detail
            content.sound = nil  // the spoken warning already plays
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: w.id.uuidString, content: content, trigger: nil))
        }
        warningTask?.cancel()
        warningTask = Task {
            try? await Task.sleep(for: .seconds(12))
            if !Task.isCancelled, self.warning?.id == w.id { self.warning = nil }
        }
    }

    private func refreshCommunityData(around c: CLLocationCoordinate2D) async {
        async let pins = ServerClient.shared.recentReports(around: c)
        async let spots = ServerClient.shared.hotspots(around: c)
        nearbyPins = await pins
        communityHotspots = await spots
    }
}
