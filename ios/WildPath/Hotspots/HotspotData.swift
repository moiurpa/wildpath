import Foundation
import CoreLocation

/// One state-highway stretch from Vermont's Wildlife Crossing Value data.
struct HotspotSegment {
    let score: Double
    let route: String
    let fromMile: Double
    let toMile: Double
    let lines: [[CLLocationCoordinate2D]]
}

/// Loads the bundled road data (Resources/hotspot-segments.json, made by
/// hotspot-map/build.py) and finds stretches near the car quickly.
final class HotspotData {
    static let shared = HotspotData()

    private(set) var segments: [HotspotSegment] = []
    private var grid: [Int64: [Int]] = [:]
    private let cellDegrees = 0.02  // about 2 km

    private init() {
        load()
    }

    /// Segments with any part within `radius` meters of `center` (approximate).
    func segments(near center: CLLocationCoordinate2D, radius: CLLocationDistance) -> [Int] {
        let dLat = radius / 111_000
        let dLon = dLat / max(cos(center.latitude * .pi / 180), 0.01)
        var found = Set<Int>()
        for row in cell(center.latitude - dLat)...cell(center.latitude + dLat) {
            for col in cell(center.longitude - dLon)...cell(center.longitude + dLon) {
                grid[key(row, col)]?.forEach { found.insert($0) }
            }
        }
        return Array(found)
    }

    private func cell(_ degrees: Double) -> Int { Int(floor(degrees / cellDegrees)) }
    private func key(_ row: Int, _ col: Int) -> Int64 { Int64(row) << 32 | Int64(UInt32(bitPattern: Int32(col))) }

    private func load() {
        guard let url = Bundle.main.url(forResource: "hotspot-segments", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let routes = json["routes"] as? [String],
              let raw = json["segments"] as? [[Any]] else { return }

        for item in raw {
            guard item.count == 5,
                  let score = (item[0] as? NSNumber)?.doubleValue,
                  let routeIndex = (item[1] as? NSNumber)?.intValue,
                  let fromMile = (item[2] as? NSNumber)?.doubleValue,
                  let toMile = (item[3] as? NSNumber)?.doubleValue,
                  let encoded = item[4] as? [[NSNumber]] else { continue }

            // Each line is delta-encoded lat/lon at 1e-5 degrees.
            let lines: [[CLLocationCoordinate2D]] = encoded.map { values in
                var lat = 0, lon = 0
                var points: [CLLocationCoordinate2D] = []
                points.reserveCapacity(values.count / 2)
                var i = 0
                while i + 1 < values.count {
                    lat += values[i].intValue
                    lon += values[i + 1].intValue
                    points.append(CLLocationCoordinate2D(latitude: Double(lat) / 1e5, longitude: Double(lon) / 1e5))
                    i += 2
                }
                return points
            }

            let index = segments.count
            segments.append(HotspotSegment(score: score, route: routes[safe: routeIndex] ?? "State highway",
                                           fromMile: fromMile, toMile: toMile, lines: lines))

            var cells = Set<Int64>()
            for line in lines {
                for p in line { cells.insert(key(cell(p.latitude), cell(p.longitude))) }
            }
            for c in cells { grid[c, default: []].append(index) }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
