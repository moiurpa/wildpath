import Foundation
import CoreLocation

/// One animal sighting. Matches the `reports` table in the database design:
/// no names or emails, only an anonymous device ID added at upload time.
struct Report: Codable, Identifiable, Hashable, Sendable {
    enum Source: String, Codable, Sendable {
        case carplay, phone, siri, camera
    }

    let id: UUID
    let species: Species
    let latitude: Double
    let longitude: Double
    /// GPS accuracy in meters.
    let horizontalAccuracy: Double
    /// Vehicle speed and heading at report time. Used later to snap the pin to
    /// the right road and to correct for the car having already passed the animal.
    let speedMetersPerSecond: Double?
    let courseDegrees: Double?
    /// When the button was tapped, not when the report was uploaded.
    let observedAt: Date
    let source: Source
    /// How sure the camera detector was (0-1). Nil for reports made by a person.
    let confidence: Double?
    var uploaded: Bool

    init(species: Species, location: CLLocation, observedAt: Date, source: Source, confidence: Double? = nil) {
        self.id = UUID()
        self.species = species
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
        self.horizontalAccuracy = location.horizontalAccuracy
        self.speedMetersPerSecond = location.speed >= 0 ? location.speed : nil
        self.courseDegrees = location.course >= 0 ? location.course : nil
        self.observedAt = observedAt
        self.source = source
        self.confidence = confidence
        self.uploaded = false
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
