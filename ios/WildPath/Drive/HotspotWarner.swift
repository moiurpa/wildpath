import Foundation
import CoreLocation

struct HotspotWarning: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String
    let spoken: String
    let level: RiskModel.Level
}

/// Looks down the road the car is driving and warns about wildlife hotspots
/// ahead: risky stretches from the state data, and spots where other drivers
/// have reported several animals.
@MainActor
final class HotspotWarner {
    /// Only warn about these levels from the state data. Warnings heard too
    /// often get ignored (the reason static deer signs barely work), so the
    /// habitat-based ones are kept for the riskiest stretches only.
    var minimumLevel: RiskModel.Level = .veryHigh
    /// At least this long between habitat-based warnings of any kind.
    var minimumGap: TimeInterval = 240
    /// Community hotspots need at least this many reports.
    var minimumCommunityReports = 3

    private let data = HotspotData.shared
    private let headingTolerance = 25.0  // degrees either side of the car's heading
    private var lastWarnedKey: String?
    private var lastWarnedAt: Date?
    private var lastWarnedLocation: CLLocation?
    private var lastHabitatWarningAt: Date?

    func evaluate(_ location: CLLocation, community: [ServerClient.CommunityHotspot],
                  now: Date = Date()) -> HotspotWarning? {
        // Need a moving car with a known heading and a decent GPS fix.
        guard location.speed >= 6, location.course >= 0, location.horizontalAccuracy >= 0,
              location.horizontalAccuracy < 50 else { return nil }

        // Look about 45 seconds ahead, between 600 m and 2 km.
        let lookahead = min(2000, max(600, location.speed * 45))
        let month = SunClock.month(now)
        let period = SunClock.period(at: location.coordinate, date: now)

        var best: (key: String, warning: HotspotWarning, distance: Double)?
        let habitatAllowed = lastHabitatWarningAt.map { now.timeIntervalSince($0) >= minimumGap } ?? true

        for index in (habitatAllowed ? data.segments(near: location.coordinate, radius: lookahead) : []) {
            let seg = data.segments[index]
            let (level, group) = RiskModel.worst(score: seg.score, month: month, period: period)
            guard level >= minimumLevel,
                  let distance = distanceAhead(of: location, to: seg.lines, within: lookahead) else { continue }
            if let b = best, b.warning.level > level || (b.warning.level == level && b.distance <= distance) {
                continue
            }
            let when = "\(period.rawValue) in \(monthName(month))"
            best = (seg.route, HotspotWarning(
                title: "\(level.label) wildlife risk ahead",
                detail: "\(seg.route), \(feetOrMiles(distance)) ahead · \(group.label), \(when)",
                spoken: "Wildlife crossing area ahead on \(spokenRoute(seg.route)). \(level.label) risk for \(group.label) at \(period.rawValue).",
                level: level), distance)
        }

        for spot in community where spot.count >= minimumCommunityReports {
            let here = CLLocation(latitude: spot.coordinate.latitude, longitude: spot.coordinate.longitude)
            guard let distance = distanceAhead(of: location, to: [[spot.coordinate]], within: lookahead),
                  best == nil || best!.warning.level < .veryHigh else { continue }
            let animal = spot.topSpecies?.displayName.lowercased() ?? "animals"
            best = ("community-\(spot.id)", HotspotWarning(
                title: "\(spot.count) animals reported ahead",
                detail: "Drivers reported \(spot.count) animals here, mostly \(animal) · \(feetOrMiles(distance)) ahead",
                spoken: "Caution. Drivers have reported \(spot.count) animals on the road ahead.",
                level: .veryHigh), here.distance(from: location))
        }

        guard let chosen = best, shouldWarn(key: chosen.key, at: location, now: now) else { return nil }
        if !chosen.key.hasPrefix("community-") { lastHabitatWarningAt = now }
        lastWarnedKey = chosen.key
        lastWarnedAt = now
        lastWarnedLocation = location
        return chosen.warning
    }

    /// Don't repeat a warning for the same road within 3 km or 10 minutes.
    private func shouldWarn(key: String, at location: CLLocation, now: Date) -> Bool {
        guard key == lastWarnedKey, let at = lastWarnedAt, let from = lastWarnedLocation else { return true }
        return now.timeIntervalSince(at) > 600 || location.distance(from: from) > 3000
    }

    /// Distance to the nearest point of these lines that lies ahead of the car
    /// (within the heading tolerance), or nil if none is ahead.
    private func distanceAhead(of car: CLLocation, to lines: [[CLLocationCoordinate2D]],
                               within limit: Double) -> Double? {
        var nearest: Double?
        for line in lines {
            for p in line {
                let point = CLLocation(latitude: p.latitude, longitude: p.longitude)
                let d = car.distance(from: point)
                guard d >= 80, d <= limit else { continue }
                let off = angleDifference(bearing(from: car.coordinate, to: p), car.course)
                if off <= headingTolerance, d < (nearest ?? .infinity) { nearest = d }
            }
        }
        return nearest
    }

    private func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    private func angleDifference(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }

    private func feetOrMiles(_ meters: Double) -> String {
        let miles = meters / 1609.344
        return miles < 0.2 ? "\(Int((meters * 3.281 / 50).rounded()) * 50) ft" : String(format: "%.1f mi", miles)
    }

    /// "VT 105" reads as "V T 105" in speech; say "Route 105" instead.
    private func spokenRoute(_ route: String) -> String {
        route.replacingOccurrences(of: "VT ", with: "Route ")
            .replacingOccurrences(of: "US ", with: "U.S. ")
            .replacingOccurrences(of: "I-", with: "Interstate ")
    }

    private func monthName(_ month: Int) -> String {
        DateFormatter().monthSymbols[month]
    }
}
