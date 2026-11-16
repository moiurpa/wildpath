import Foundation
import CoreLocation

/// The same risk model as the web map (hotspot-map/template.html):
/// risk = crossing value (where) x season x time of day (when).
/// The season and time factors are estimates until real report data replaces them.
enum RiskModel {
    enum Group: String, CaseIterable {
        case deer, moose, small

        var label: String {
            switch self {
            case .deer: return "deer"
            case .moose: return "moose"
            case .small: return "small animals"
            }
        }
    }

    enum Period: String, CaseIterable {
        case dawn, day, dusk, night
    }

    enum Level: Int, Comparable {
        case low, moderate, high, veryHigh

        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        var label: String {
            switch self {
            case .low: return "Low"
            case .moderate: return "Moderate"
            case .high: return "High"
            case .veryHigh: return "Very high"
            }
        }
    }

    static let season: [Group: [Double]] = [
        .deer:  [0.6, 0.5, 0.5, 0.6, 0.9, 1.0, 0.7, 0.7, 0.9, 1.5, 2.0, 1.2],
        .moose: [0.5, 0.4, 0.4, 0.6, 1.6, 1.8, 1.2, 0.9, 1.0, 1.1, 0.9, 0.6],
        .small: Array(repeating: 1.0, count: 12),
    ]

    static let time: [Group: [Period: Double]] = [
        .deer:  [.dawn: 3, .day: 1, .dusk: 4, .night: 2],
        .moose: [.dawn: 3, .day: 1, .dusk: 3, .night: 3],
        .small: [.dawn: 2, .day: 1, .dusk: 3, .night: 3],
    ]

    static let thresholds = [0.2, 0.4, 0.7]

    /// month is 0-11.
    static func value(score: Double, group: Group, month: Int, period: Period) -> Double {
        let base = 0.3 + 0.7 * (score - 5) / 4
        let seasons = season[group]!
        let times = time[group]!
        let s = seasons[month] / seasons.max()!
        let t = times[period]! / times.values.max()!
        return base * s * t
    }

    static func level(_ value: Double) -> Level {
        Level(rawValue: thresholds.filter { value >= $0 }.count) ?? .low
    }

    /// The riskiest animal group for this road right now. Compares the exact
    /// values, so in November deer win over small animals at the same level.
    static func worst(score: Double, month: Int, period: Period) -> (level: Level, group: Group) {
        // On a tie, name the larger animal: deer and moose are the bigger danger to drivers.
        let priority: [Group: Int] = [.deer: 3, .moose: 2, .small: 1]
        let best = Group.allCases
            .map { (value(score: score, group: $0, month: month, period: period), $0) }
            .max { ($0.0, priority[$0.1]!) < ($1.0, priority[$1.1]!) }!
        return (level(best.0), best.1)
    }

    static func group(for species: Species) -> Group {
        switch species {
        case .deer: return .deer
        case .moose: return .moose
        default: return .small
        }
    }
}

/// Dawn, day, dusk or night at a place and time (NOAA approximation).
enum SunClock {
    static func period(at c: CLLocationCoordinate2D, date: Date = Date()) -> RiskModel.Period {
        let utc = TimeZone(identifier: "UTC")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        // Local solar date, so an evening in Vermont uses that day's sunset.
        let solar = date.addingTimeInterval(c.longitude / 15 * 3600)
        let dayOfYear = cal.ordinality(of: .day, in: .year, for: solar) ?? 1

        let g = 2 * Double.pi / 365 * Double(dayOfYear - 1)
        let eqt = 229.18 * (0.000075 + 0.001868 * cos(g) - 0.032077 * sin(g)
                            - 0.014615 * cos(2 * g) - 0.040849 * sin(2 * g))
        let decl = 0.006918 - 0.399912 * cos(g) + 0.070257 * sin(g) - 0.006758 * cos(2 * g)
            + 0.000907 * sin(2 * g) - 0.002697 * cos(3 * g) + 0.00148 * sin(3 * g)
        let lat = c.latitude * .pi / 180
        let cosHA = cos(90.833 * .pi / 180) / (cos(lat) * cos(decl)) - tan(lat) * tan(decl)
        if cosHA > 1 { return .night }
        if cosHA < -1 { return .day }
        let ha = acos(cosHA) * 180 / .pi
        let rise = 720 - 4 * (c.longitude + ha) - eqt
        let set = 720 - 4 * (c.longitude - ha) - eqt

        let parts = cal.dateComponents([.hour, .minute], from: date)
        let now = Double(parts.hour! * 60 + parts.minute!)
        func diff(_ a: Double, _ b: Double) -> Double {
            (((a - b + 720).truncatingRemainder(dividingBy: 1440)) + 1440).truncatingRemainder(dividingBy: 1440) - 720
        }
        if abs(diff(now, rise)) <= 60 { return .dawn }
        if abs(diff(now, set)) <= 60 { return .dusk }
        if diff(now, rise) > 60 && diff(now, set) < -60 { return .day }
        return .night
    }

    /// 0-11, in the phone's own time zone.
    static func month(_ date: Date = Date()) -> Int {
        Calendar.current.component(.month, from: date) - 1
    }
}
