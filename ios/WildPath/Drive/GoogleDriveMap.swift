import GoogleMaps
import SwiftUI

enum GoogleMapsConfig {
    /// Set `GoogleMapsAPIKey` in Info.plist. Get a key from Google Cloud
    /// (Maps SDK for iOS) and restrict it to this app's bundle ID.
    static var apiKey: String? {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "GoogleMapsAPIKey") as? String,
              !key.isEmpty else { return nil }
        return key
    }

    static var isConfigured: Bool { apiKey != nil }

    static func configure() {
        if let apiKey { GMSServices.provideAPIKey(apiKey) }
    }
}

/// Google's map with WildPath drawn on top: risky road stretches colored by
/// level, animal pins, and community hotspots. Follows the car while driving.
@MainActor
struct GoogleDriveMap: UIViewRepresentable {
    @ObservedObject var session: DriveSession
    @ObservedObject var store: ReportStore
    @Environment(\.colorScheme) private var colorScheme

    static let montpelier = CLLocationCoordinate2D(latitude: 44.26, longitude: -72.58)

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeUIView(context: Context) -> GMSMapView {
        let map = GMSMapView(frame: .zero)
        map.isMyLocationEnabled = true
        map.settings.myLocationButton = false
        map.settings.compassButton = true
        map.delegate = context.coordinator
        let start = session.location?.coordinate ?? Self.montpelier
        map.camera = GMSCameraPosition(target: start, zoom: session.location == nil ? 9 : 15)
        return map
    }

    func updateUIView(_ map: GMSMapView, context: Context) {
        let c = context.coordinator
        c.applyStyle(map, dark: colorScheme == .dark)
        c.updateHotspots(map, around: session.location, month: session.month, period: session.period)
        c.updatePins(map, own: store.reports, others: session.nearbyPins, community: session.communityHotspots)
        if session.followCar, let loc = session.location {
            c.follow(map, loc, driving: session.isDriving)
        }
    }

    final class Coordinator: NSObject, GMSMapViewDelegate {
        private let session: DriveSession
        private var dark: Bool?
        private var hotspotLines: [GMSPolyline] = []
        private var drawnCenter: CLLocation?
        private var drawnKey = ""
        private var pinOverlays: [GMSOverlay] = []
        private var pinSignature = ""
        private var movingByCode = false

        init(session: DriveSession) {
            self.session = session
        }

        // MARK: Camera

        func follow(_ map: GMSMapView, _ loc: CLLocation, driving: Bool) {
            let bearing = (driving && loc.course >= 0 && loc.speed > 2) ? loc.course : map.camera.bearing
            let zoom: Float = driving ? (loc.speed > 22 ? 15 : 16) : max(map.camera.zoom, 14)
            movingByCode = true
            map.animate(to: GMSCameraPosition(target: loc.coordinate, zoom: zoom, bearing: bearing,
                                              viewingAngle: driving ? 45 : 0))
        }

        /// Panning the map by hand stops following until the driver taps Recenter.
        func mapView(_ mapView: GMSMapView, willMove gesture: Bool) {
            guard gesture else { return }
            Task { @MainActor in self.session.followCar = false }
        }

        // MARK: Style

        func applyStyle(_ map: GMSMapView, dark: Bool) {
            guard self.dark != dark else { return }
            self.dark = dark
            map.mapStyle = dark ? (try? GMSMapStyle(jsonString: Self.darkStyle)) : nil
        }

        // MARK: Hotspot roads

        func updateHotspots(_ map: GMSMapView, around loc: CLLocation?, month: Int, period: RiskModel.Period) {
            let center = loc ?? CLLocation(latitude: GoogleDriveMap.montpelier.latitude,
                                           longitude: GoogleDriveMap.montpelier.longitude)
            let key = "\(month)-\(period.rawValue)"
            if let drawn = drawnCenter, center.distance(from: drawn) < 2000, key == drawnKey { return }
            drawnCenter = center
            drawnKey = key

            hotspotLines.forEach { $0.map = nil }
            hotspotLines.removeAll()

            let data = HotspotData.shared
            for index in data.segments(near: center.coordinate, radius: 15_000) {
                let seg = data.segments[index]
                let level = RiskModel.worst(score: seg.score, month: month, period: period).level
                guard level >= .moderate else { continue }
                for line in seg.lines where line.count >= 2 {
                    let path = GMSMutablePath()
                    line.forEach { path.add($0) }
                    let polyline = GMSPolyline(path: path)
                    polyline.strokeColor = Self.color(level)
                    polyline.strokeWidth = Self.width(level)
                    polyline.zIndex = Int32(level.rawValue)
                    polyline.map = map
                    hotspotLines.append(polyline)
                }
            }
        }

        static func color(_ level: RiskModel.Level) -> UIColor {
            switch level {
            case .low: return UIColor(red: 0.65, green: 0.72, blue: 0.68, alpha: 0.7)
            case .moderate: return UIColor(red: 0.89, green: 0.70, blue: 0.12, alpha: 0.85)
            case .high: return UIColor(red: 0.87, green: 0.47, blue: 0.09, alpha: 0.9)
            case .veryHigh: return UIColor(red: 0.77, green: 0.18, blue: 0.11, alpha: 0.95)
            }
        }

        static func width(_ level: RiskModel.Level) -> CGFloat {
            [2, 4, 6, 8][level.rawValue]
        }

        // MARK: Pins

        func updatePins(_ map: GMSMapView, own: [Report], others: [ServerClient.Pin],
                        community: [ServerClient.CommunityHotspot]) {
            let cutoff = Date().addingTimeInterval(-30 * 86_400)
            let recentOwn = own.filter { $0.observedAt > cutoff }
            let ownIDs = Set(recentOwn.map { $0.id.uuidString.lowercased() })
            let signature = "\(recentOwn.count)|\(recentOwn.first?.id.uuidString ?? "")|\(others.count)|\(community.count)"
            guard signature != pinSignature else { return }
            pinSignature = signature

            pinOverlays.forEach { $0.map = nil }
            pinOverlays.removeAll()

            for spot in community {
                let circle = GMSCircle(position: spot.coordinate, radius: 300)
                circle.fillColor = UIColor.systemRed.withAlphaComponent(0.18)
                circle.strokeColor = UIColor.systemRed.withAlphaComponent(0.6)
                circle.strokeWidth = 1
                circle.map = map
                pinOverlays.append(circle)
            }

            let formatter = RelativeDateTimeFormatter()
            for report in recentOwn {
                let marker = GMSMarker(position: report.coordinate)
                marker.title = "\(report.species.displayName) (your report)"
                marker.snippet = formatter.localizedString(for: report.observedAt, relativeTo: Date())
                marker.icon = GMSMarker.markerImage(with: .systemBlue)
                marker.map = map
                pinOverlays.append(marker)
            }

            for pin in others where !ownIDs.contains(pin.id) {
                let marker = GMSMarker(position: pin.coordinate)
                marker.title = pin.species.displayName
                marker.snippet = pin.observedAt.map { formatter.localizedString(for: $0, relativeTo: Date()) }
                marker.icon = GMSMarker.markerImage(with: pin.status == "unverified" ? .systemGray : .systemPurple)
                marker.map = map
                pinOverlays.append(marker)
            }
        }

        /// A quiet dark map so the colored roads stand out at night.
        static let darkStyle = """
        [
          {"elementType":"geometry","stylers":[{"color":"#1d2620"}]},
          {"elementType":"labels.text.fill","stylers":[{"color":"#9aa89e"}]},
          {"elementType":"labels.text.stroke","stylers":[{"color":"#111813"}]},
          {"featureType":"road","elementType":"geometry","stylers":[{"color":"#38433b"}]},
          {"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#4a564d"}]},
          {"featureType":"water","elementType":"geometry","stylers":[{"color":"#0f1a22"}]},
          {"featureType":"poi","stylers":[{"visibility":"off"}]}
        ]
        """
    }
}
