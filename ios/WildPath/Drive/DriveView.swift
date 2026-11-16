import SwiftUI

/// The main driving screen: Google's map with hotspots, warnings at the top,
/// and one-tap animal buttons at the bottom.
@MainActor
struct DriveView: View {
    @ObservedObject private var session = DriveSession.shared
    @ObservedObject private var store = ReportStore.shared
    @ObservedObject private var camera = DriveSession.shared.camera
    @State private var showAllAnimals = false
    @State private var showCameraSettings = false
    @State private var showDirections = false

    var body: some View {
        ZStack {
            if GoogleMapsConfig.isConfigured {
                GoogleDriveMap(session: session, store: store)
                    .ignoresSafeArea(edges: .top)
            } else {
                MissingKeyView()
            }

            VStack(spacing: 10) {
                if let warning = session.warning {
                    WarningBanner(warning: warning)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let toast = session.toast {
                    Text(toast)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                }
                Spacer()
                HStack(alignment: .bottom) {
                    if camera.isRunning {
                        CameraPreview(session: camera.session)
                            .frame(width: 90, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(alignment: .bottom) {
                                Text("Camera on").font(.caption2.weight(.bold))
                                    .padding(4).background(.black.opacity(0.6), in: Capsule())
                                    .foregroundStyle(.white).padding(4)
                            }
                            .accessibilityLabel("Camera detection is watching the road")
                    }
                    Spacer()
                    sideButtons
                }
                if session.isDriving {
                    ReportBar(onReport: session.report, onMore: { showAllAnimals = true })
                }
                driveButton
            }
            .padding()
        }
        .animation(.easeInOut(duration: 0.25), value: session.warning)
        .sheet(isPresented: $showAllAnimals) {
            AllAnimalsSheet { species in
                session.report(species)
                showAllAnimals = false
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showCameraSettings) { CameraConsentView(camera: camera) }
        .sheet(isPresented: $showDirections) { DirectionsSheet() }
    }

    private var sideButtons: some View {
        VStack(spacing: 10) {
            if !session.followCar {
                MapButton(symbol: "location.north.line.fill", label: "Recenter") { session.followCar = true }
            }
            MapButton(symbol: camera.isRunning ? "video.fill" : "video.slash",
                      label: camera.isRunning ? "Turn off camera detection" : "Camera detection") {
                if !camera.isConsented {
                    showCameraSettings = true
                } else if camera.isRunning {
                    camera.wantsToRun = false
                    camera.stop()
                } else {
                    camera.wantsToRun = true
                    if session.isDriving { camera.start() } else { showCameraSettings = true }
                }
            }
            MapButton(symbol: "arrow.triangle.turn.up.right.diamond.fill", label: "Directions") {
                showDirections = true
            }
        }
    }

    private var driveButton: some View {
        Button {
            session.isDriving ? session.endDrive() : session.startDrive()
        } label: {
            Text(session.isDriving ? "End drive" : "Start drive")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.borderedProminent)
        .tint(session.isDriving ? .gray : .orange)
    }
}

// MARK: - Pieces

@MainActor
struct WarningBanner: View {
    let warning: HotspotWarning

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.black)
                .frame(width: 40, height: 40)
                .background(Color.yellow, in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(warning.title).font(.headline)
                Text(warning.detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(levelColor, lineWidth: 3))
        .accessibilityElement(children: .combine)
    }

    private var levelColor: Color {
        switch warning.level {
        case .veryHigh: return .red
        case .high: return .orange
        default: return .yellow
        }
    }
}

/// Big one-tap buttons: the common animals plus "More".
@MainActor
struct ReportBar: View {
    let onReport: @MainActor (Species) -> Void
    let onMore: @MainActor () -> Void
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Species.carPlayQuickPicks) { species in
                Button { onReport(species) } label: {
                    VStack(spacing: 2) {
                        Image(systemName: species.symbol)
                        Text(species.displayName).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.bordered)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            Button(action: onMore) {
                VStack(spacing: 2) {
                    Image(systemName: "ellipsis.circle.fill")
                    Text("More").font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.bordered)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

@MainActor
struct AllAnimalsSheet: View {
    let onPick: @MainActor (Species) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(Species.Group.allCases) { group in
                    Section(group.rawValue) {
                        ForEach(Species.allCases.filter { $0.group == group }) { species in
                            Button { onPick(species) } label: {
                                Label(species.displayName, systemImage: species.symbol)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Report an animal")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

@MainActor
struct MapButton: View {
    let symbol: String
    let label: String
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 48, height: 48)
                .background(.regularMaterial, in: Circle())
        }
        .accessibilityLabel(label)
    }
}

@MainActor
struct MissingKeyView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Map needs a Google Maps key", systemImage: "map")
        } description: {
            Text("Add your key as GoogleMapsAPIKey in Info.plist. Hotspot warnings and reporting still work without the map.")
        }
    }
}

/// Step 5 for now: hand directions to the Google Maps app. WildPath keeps
/// running in the background and speaks hotspot warnings over the directions.
@MainActor
struct DirectionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var destination = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Where to?", text: $destination)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.go)
                        .onSubmit(go)
                } footer: {
                    Text("Directions open in Google Maps. WildPath keeps running and will speak wildlife warnings while you drive.")
                }
                Button("Get directions in Google Maps", action: go)
                    .disabled(destination.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .navigationTitle("Directions")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func go() {
        let place = destination.trimmingCharacters(in: .whitespaces)
        guard !place.isEmpty,
              let encoded = place.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let app = URL(string: "comgooglemaps://?daddr=\(encoded)&directionsmode=driving"),
              let web = URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(encoded)&travelmode=driving")
        else { return }
        DriveSession.shared.startDrive()
        // Use the Google Maps app if installed, otherwise Google Maps on the web.
        openURL(app) { opened in
            if !opened { openURL(web) }
        }
        dismiss()
    }
}
