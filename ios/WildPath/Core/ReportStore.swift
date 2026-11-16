import Foundation

/// Saves reports on the phone first, so reporting works with no cell signal
/// (common on rural Vermont roads). Uploads happen later.
@MainActor
final class ReportStore: ObservableObject {
    static let shared = ReportStore()

    @Published private(set) var reports: [Report] = []

    private let fileURL: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("reports.json")
        load()
    }

    var pending: [Report] { reports.filter { !$0.uploaded } }

    func add(_ report: Report) {
        reports.insert(report, at: 0)
        save()
    }

    func delete(ids: Set<UUID>) {
        reports.removeAll { ids.contains($0.id) }
        save()
    }

    func markUploaded(_ ids: Set<UUID>) {
        for index in reports.indices where ids.contains(reports[index].id) {
            reports[index].uploaded = true
        }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? decoder.decode([Report].self, from: data) else { return }
        reports = saved
    }

    private func save() {
        guard let data = try? encoder.encode(reports) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
