import AVFoundation
import CoreLocation
import UIKit
import Vision

/// Watches the road through a dashboard-mounted phone and reports animals
/// automatically. Off by default and only runs after the driver agrees.
///
/// Privacy: frames are looked at in memory and thrown away. No photo or video
/// is saved or uploaded; a report holds only the animal, place, time and how
/// sure the detector was.
final class CameraDetectionService: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published private(set) var isRunning = false
    @Published private(set) var status = "Camera detection is off"
    @Published private(set) var lastDetection: String?
    /// The driver's on/off switch, remembered between drives.
    @Published var wantsToRun: Bool {
        didSet { UserDefaults.standard.set(wantsToRun, forKey: Self.wantsKey) }
    }

    let session = AVCaptureSession()

    private static let consentKey = "cameraDetectionConsent"
    private static let wantsKey = "cameraDetectionOn"
    private let sessionQueue = DispatchQueue(label: "wildpath.camera.session")
    private let frameQueue = DispatchQueue(label: "wildpath.camera.frames")
    private var configured = false

    // Only touched on frameQueue.
    private lazy var detector: AnimalDetector = AnimalDetectors.best()
    private var lastAnalysis: CFTimeInterval = 0
    private var recent: [Species?] = []
    private var lastTrigger: CFTimeInterval = 0
    private var orientation: CGImagePropertyOrientation = .right

    private let speedLock = NSLock()
    private var _speed: Double = 0
    /// Set by the drive session; detection only runs while the car is moving.
    var currentSpeed: Double {
        get { speedLock.lock(); defer { speedLock.unlock() }; return _speed }
        set { speedLock.lock(); _speed = newValue; speedLock.unlock() }
    }

    // Main-thread state for spacing out reports.
    private var lastReportLocation: CLLocation?

    override init() {
        wantsToRun = UserDefaults.standard.bool(forKey: Self.wantsKey)
        super.init()
    }

    var isConsented: Bool { UserDefaults.standard.bool(forKey: Self.consentKey) }

    func setConsent(_ allowed: Bool) {
        UserDefaults.standard.set(allowed, forKey: Self.consentKey)
        if !allowed {
            wantsToRun = false
            stop()
        }
    }

    // MARK: Start / stop

    func start() {
        guard isConsented else { return }
        orientation = Self.visionOrientation(for: UIDevice.current.orientation)
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else {
                self.publish { $0.status = "Camera access is off. Turn it on in Settings › WildPath." }
                return
            }
            self.sessionQueue.async {
                self.configureIfNeeded()
                guard self.configured else { return }
                self.session.startRunning()
                self.publish {
                    $0.isRunning = true
                    $0.status = "Watching the road"
                }
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.publish {
                $0.isRunning = false
                $0.status = "Camera detection is off"
            }
        }
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .hd1280x720
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else {
            publish { $0.status = "No back camera available." }
            return
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frameQueue)
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        configured = true
    }

    // MARK: Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Two frames a second is enough at road speed and keeps the phone cool.
        let now = CACurrentMediaTime()
        guard now - lastAnalysis >= 0.5 else { return }
        lastAnalysis = now

        guard currentSpeed >= 4 else { return }  // about 9 mph
        if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
            publish { $0.status = "Paused: the phone is too hot" }
            return
        }
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let detection = detector.detect(in: pixels, orientation: orientation)
        recent.append(detection?.species)
        if recent.count > 3 { recent.removeFirst() }

        // Need the same kind of animal in 2 of the last 3 frames, so one odd
        // frame (a shadow, a leaf) doesn't create a report.
        guard let detection,
              recent.compactMap({ $0 }).filter({ RiskModel.group(for: $0) == RiskModel.group(for: detection.species) }).count >= 2,
              now - lastTrigger > 10 else { return }
        lastTrigger = now
        recent.removeAll()

        Task { @MainActor in self.report(detection) }
    }

    @MainActor
    private func report(_ detection: AnimalDetection) {
        // Don't report again within 100 m of the last camera report.
        if let here = LocationProvider.shared.lastLocation, let last = lastReportLocation,
           here.distance(from: last) < 100 { return }
        lastReportLocation = LocationProvider.shared.lastLocation
        Task { @MainActor in
            let outcome = await ReportService.shared.report(detection.species, source: .camera,
                                                            confidence: Double(detection.confidence))
            if case .saved = outcome {
                let percent = Int(detection.confidence * 100)
                self.lastDetection = "\(detection.species.displayName) detected (\(percent)% sure) and reported"
                DriveSession.shared.showToast(self.lastDetection!)
                Speaker.shared.say("\(detection.species.displayName) detected and reported.")
            }
        }
    }

    // MARK: Helpers

    private func publish(_ change: @escaping (CameraDetectionService) -> Void) {
        DispatchQueue.main.async { change(self) }
    }

    /// The back camera's picture orientation for how the phone is mounted.
    static func visionOrientation(for device: UIDeviceOrientation) -> CGImagePropertyOrientation {
        switch device {
        case .landscapeLeft: return .up
        case .landscapeRight: return .down
        case .portraitUpsideDown: return .left
        default: return .right
        }
    }
}
