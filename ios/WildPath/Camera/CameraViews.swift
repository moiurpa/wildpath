import AVFoundation
import SwiftUI

/// Explains exactly what camera detection does before the driver turns it on.
@MainActor
struct CameraConsentView: View {
    @ObservedObject var camera: CameraDetectionService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Mount your phone on the dashboard with the back camera facing the road.", systemImage: "iphone.rear.camera")
                    Label("While you drive, WildPath looks for animals on the road and reports them for you.", systemImage: "pawprint.fill")
                    Label("Only runs while the car is moving, and pauses if the phone gets hot.", systemImage: "thermometer.medium")
                } header: {
                    Text("How it works")
                }

                Section {
                    Label("Video and photos never leave your phone and are never saved.", systemImage: "lock.fill")
                    Label("A report holds only the animal, the place, the time and how sure the camera was.", systemImage: "mappin.and.ellipse")
                    Label("Camera reports stay hidden from the public map until another driver reports the same animal.", systemImage: "checkmark.shield")
                    Label("You can turn it off at any time.", systemImage: "power")
                } header: {
                    Text("Your privacy")
                }

                Section {
                    Toggle("Allow camera detection", isOn: Binding(
                        get: { camera.isConsented && camera.wantsToRun },
                        set: { on in
                            camera.setConsent(on)
                            camera.wantsToRun = on
                            if on && DriveSession.shared.isDriving { camera.start() }
                        }))
                } footer: {
                    Text("Test version: until WildPath's own animal model is trained, detection uses Apple's general image recognizer and will miss many animals.")
                }
            }
            .navigationTitle("Camera detection")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// Small live view so the driver can aim the phone when mounting it.
@MainActor
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
