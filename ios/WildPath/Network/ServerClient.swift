import Foundation
import CoreLocation

/// Reads other drivers' reports and community hotspots from the WildPath server.
@MainActor
final class ServerClient {
    static let shared = ServerClient()
    private init() {}

    /// Set `WildPathServerURL` in Info.plist, for example https://api.example.org
    static var baseURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "WildPathServerURL") as? String,
              !value.isEmpty else { return nil }
        return URL(string: value)
    }

    struct Pin: Identifiable, Hashable {
        let id: String
        let species: Species
        let coordinate: CLLocationCoordinate2D
        let observedAt: Date?
        let status: String

        static func == (a: Pin, b: Pin) -> Bool { a.id == b.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    struct CommunityHotspot: Identifiable {
        let id: String
        let count: Int
        let coordinate: CLLocationCoordinate2D
        let topSpecies: Species?
    }

    /// A box around a point, in the server's minLon,minLat,maxLon,maxLat form.
    static func bbox(around c: CLLocationCoordinate2D, degrees: Double = 0.15) -> String {
        String(format: "%.4f,%.4f,%.4f,%.4f",
               c.longitude - degrees, c.latitude - degrees, c.longitude + degrees, c.latitude + degrees)
    }

    func recentReports(around c: CLLocationCoordinate2D, days: Int = 30) async -> [Pin] {
        guard let json = await get("v1/reports", ["bbox": Self.bbox(around: c), "days": "\(days)"]),
              let features = json["features"] as? [[String: Any]] else { return [] }
        let iso = ISO8601DateFormatter()
        return features.compactMap { f in
            guard let geom = f["geometry"] as? [String: Any],
                  let coords = geom["coordinates"] as? [Double], coords.count == 2,
                  let props = f["properties"] as? [String: Any],
                  let id = props["id"] as? String else { return nil }
            let species = Species(rawValue: props["species"] as? String ?? "") ?? .unknown
            return Pin(id: id.lowercased(), species: species,
                       coordinate: CLLocationCoordinate2D(latitude: coords[1], longitude: coords[0]),
                       observedAt: (props["observedAt"] as? String).flatMap(iso.date(from:)),
                       status: props["status"] as? String ?? "new")
        }
    }

    func hotspots(around c: CLLocationCoordinate2D, minCount: Int = 3) async -> [CommunityHotspot] {
        guard let json = await get("v1/hotspots", ["bbox": Self.bbox(around: c), "min_count": "\(minCount)"]),
              let cells = json["cells"] as? [[String: Any]] else { return [] }
        return cells.compactMap { cell in
            guard let id = cell["cell"] as? String, let count = cell["count"] as? Int,
                  let center = cell["center"] as? [Double], center.count == 2 else { return nil }
            let top = (cell["species"] as? [String: Int])?.max { $0.value < $1.value }?.key
            return CommunityHotspot(id: id, count: count,
                                    coordinate: CLLocationCoordinate2D(latitude: center[0], longitude: center[1]),
                                    topSpecies: top.flatMap(Species.init(rawValue:)))
        }
    }

    private func get(_ path: String, _ query: [String: String]) async -> [String: Any]? {
        guard let base = Self.baseURL,
              var parts = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        else { return nil }
        parts.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = parts.url else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil  // offline: the map just shows the phone's own data
        }
    }
}
