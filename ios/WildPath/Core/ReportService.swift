import Foundation

/// The one place a report is created. CarPlay, the phone screen, and Siri all
/// call this, so they behave the same way.
@MainActor
final class ReportService {
    static let shared = ReportService()

    enum Outcome {
        case saved(Report)
        case duplicate
        case failed(String)
    }

    /// Ignore a second tap on the same animal within this window, so a bumpy
    /// road or a double tap doesn't create two pins for one animal.
    private let duplicateWindow: TimeInterval = 30
    private var lastTap: (species: Species, at: Date)?

    private init() {}

    func report(_ species: Species, source: Report.Source, confidence: Double? = nil) async -> Outcome {
        let tappedAt = Date()
        if let last = lastTap, last.species == species,
           tappedAt.timeIntervalSince(last.at) < duplicateWindow {
            return .duplicate
        }
        lastTap = (species, tappedAt)

        do {
            let location = try await LocationProvider.shared.currentLocation()
            let report = Report(species: species, location: location, observedAt: tappedAt,
                                source: source, confidence: confidence)
            ReportStore.shared.add(report)
            Task { await Uploader.shared.uploadPending() }
            return .saved(report)
        } catch {
            lastTap = nil
            let message = (error as? LocalizedError)?.errorDescription
                ?? "Couldn't get your location. Try again in a moment."
            return .failed(message)
        }
    }
}
