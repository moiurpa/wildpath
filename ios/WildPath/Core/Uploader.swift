import Foundation

/// Sends saved reports to the WildPath server (see /server). Until it's
/// running, leave `WildPathServerURL` empty in Info.plist and reports stay on the phone.
@MainActor
final class Uploader {
    static let shared = Uploader()

    private var isUploading = false
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private init() {}

    private var endpoint: URL? {
        ServerClient.baseURL?.appendingPathComponent("v1/reports")
    }

    /// A random ID made on first launch. It lets the server spot spam from one
    /// device without knowing who the person is.
    static var anonymousReporterID: String {
        let key = "anonymousReporterID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    private struct UploadBody: Encodable {
        let reporterID: String
        let appVersion: String
        let reports: [Report]
    }

    func uploadPending() async {
        guard !isUploading, let endpoint else { return }
        let pending = ReportStore.shared.pending
        guard !pending.isEmpty else { return }

        isUploading = true
        defer { isUploading = false }

        let body = UploadBody(
            reporterID: Self.anonymousReporterID,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            reports: pending
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try encoder.encode(body)
            let (_, response) = try await URLSession.shared.data(for: request)
            // The server answers for every report (accepted, duplicate, rejected
            // or already received), so a 2xx means none of them need resending.
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                ReportStore.shared.markUploaded(Set(pending.map(\.id)))
            }
        } catch {
            // No signal or server down: keep the reports and retry next time.
        }
    }
}
