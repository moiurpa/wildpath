import SwiftUI
import MapKit

@MainActor
struct ContentView: View {
    var body: some View {
        TabView {
            DriveView()
                .tabItem { Label("Drive", systemImage: "car.fill") }
            ReportView()
                .tabItem { Label("Report", systemImage: "plus.circle.fill") }
            ReportsMapView()
                .tabItem { Label("Map", systemImage: "map") }
            ReportsListView()
                .tabItem { Label("My Reports", systemImage: "list.bullet") }
        }
    }
}

// MARK: - Report

@MainActor
struct ReportView: View {
    @ObservedObject private var location = LocationProvider.shared
    @State private var message: String?
    @State private var busy = false

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    permissionBanner

                    ForEach(Species.Group.allCases) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.rawValue)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            LazyVGrid(columns: columns, spacing: 10) {
                                ForEach(Species.allCases.filter { $0.group == group }) { species in
                                    Button {
                                        Task { await tap(species) }
                                    } label: {
                                        VStack(spacing: 6) {
                                            Image(systemName: species.symbol).font(.system(size: 26))
                                            Text(species.displayName)
                                                .font(.subheadline.weight(.semibold))
                                                .multilineTextAlignment(.center)
                                        }
                                        .frame(maxWidth: .infinity, minHeight: 84)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(busy)
                                }
                            }
                        }
                    }

                    if let message {
                        Text(message)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                    }

                    Text("Only use this screen when parked or as a passenger. While driving, use the CarPlay button or say “Hey Siri, report roadkill in WildPath.”")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
            .navigationTitle("Report an animal")
        }
    }

    @ViewBuilder
    private var permissionBanner: some View {
        switch location.authorization {
        case .notDetermined:
            Button("Allow location so reports get a map pin") {
                location.requestPermission()
            }
            .buttonStyle(.borderedProminent)
        case .denied, .restricted:
            Text("Location is off. Turn it on in Settings › WildPath so reports get a map pin.")
                .font(.callout)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        default:
            EmptyView()
        }
    }

    @MainActor
    private func tap(_ species: Species) async {
        busy = true
        defer { busy = false }
        switch await ReportService.shared.report(species, source: .phone) {
        case .saved:
            message = "\(species.displayName) reported. Thank you."
        case .duplicate:
            message = "You just reported that one."
        case .failed(let reason):
            message = reason
        }
    }
}

// MARK: - Map

@MainActor
struct ReportsMapView: View {
    @ObservedObject private var store = ReportStore.shared

    var body: some View {
        Map {
            ForEach(store.reports) { report in
                Marker(report.species.displayName,
                       systemImage: report.species.symbol,
                       coordinate: report.coordinate)
            }
            UserAnnotation()
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
    }
}

// MARK: - List

@MainActor
struct ReportsListView: View {
    @ObservedObject private var store = ReportStore.shared

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.reports) { report in
                    HStack(spacing: 12) {
                        Image(systemName: report.species.symbol)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(report.species.displayName).font(.headline)
                            Text(report.observedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.subheadline)
                            Text(String(format: "%.5f, %.5f", report.latitude, report.longitude))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: report.uploaded ? "checkmark.icloud" : "icloud.and.arrow.up")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(report.uploaded ? "Uploaded" : "Waiting to upload")
                    }
                }
                .onDelete { offsets in
                    store.delete(ids: Set(offsets.map { store.reports[$0].id }))
                }
            }
            .overlay {
                if store.reports.isEmpty {
                    ContentUnavailableView("No reports yet",
                                           systemImage: "pawprint",
                                           description: Text("Animals you report show up here."))
                }
            }
            .navigationTitle("My Reports")
        }
    }
}
