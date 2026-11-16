import CoreML
import Vision

struct AnimalDetection {
    let species: Species
    let confidence: Float
}

/// Anything that can look at one camera frame and say whether an animal is on the road.
protocol AnimalDetector {
    var name: String { get }
    func detect(in pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> AnimalDetection?
}

/// Only look at the road: the lower, middle part of the frame from a
/// dashboard mount. Vision measures from the bottom-left corner.
let roadRegion = CGRect(x: 0.1, y: 0.0, width: 0.8, height: 0.6)

enum AnimalDetectors {
    /// Uses the custom roadkill model when it's in the app, otherwise Apple's
    /// built-in classifier as a stand-in.
    static func best() -> AnimalDetector {
        CoreMLAnimalDetector() ?? VisionClassifierDetector()
    }
}

/// The real detector, once trained. Add a Core ML object-detection model named
/// RoadkillDetector.mlmodel to the project (Create ML › Object Detection,
/// trained on photos people attach to reports). Its labels should match the
/// Species names, such as "raccoon" or "deer".
final class CoreMLAnimalDetector: AnimalDetector {
    let name = "WildPath roadkill model"
    private let request: VNCoreMLRequest
    private let minimumConfidence: Float = 0.6

    init?() {
        guard let url = Bundle.main.url(forResource: "RoadkillDetector", withExtension: "mlmodelc"),
              let model = try? MLModel(contentsOf: url),
              let visionModel = try? VNCoreMLModel(for: model) else { return nil }
        request = VNCoreMLRequest(model: visionModel)
        request.imageCropAndScaleOption = .scaleFill
        request.regionOfInterest = roadRegion
    }

    func detect(in pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> AnimalDetection? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
        try? handler.perform([request])
        let objects = (request.results as? [VNRecognizedObjectObservation]) ?? []
        let best = objects
            .compactMap { $0.labels.first }
            .filter { $0.confidence >= minimumConfidence }
            .max { $0.confidence < $1.confidence }
        guard let label = best else { return nil }
        return AnimalDetection(species: Species(rawValue: label.identifier) ?? .unknown,
                               confidence: label.confidence)
    }
}

/// Stand-in until the custom model exists. Apple's built-in image classifier
/// labels the whole picture, so it will miss small animals and is only good
/// enough to test the pipeline end to end, not to use for real.
final class VisionClassifierDetector: AnimalDetector {
    let name = "Apple built-in classifier (test only)"
    private let request: VNClassifyImageRequest = {
        let r = VNClassifyImageRequest()
        r.regionOfInterest = roadRegion
        return r
    }()
    private let minimumConfidence: Float = 0.35

    /// Matched in order, so specific animals win over generic words.
    private let keywords: [(String, Species)] = [
        ("moose", .moose), ("deer", .deer), ("bear", .bear),
        ("raccoon", .raccoon), ("skunk", .skunk), ("squirrel", .squirrel),
        ("porcupine", .porcupine), ("opossum", .opossum), ("possum", .opossum),
        ("woodchuck", .woodchuck), ("groundhog", .woodchuck), ("marmot", .woodchuck),
        ("rabbit", .rabbit), ("hare", .rabbit), ("chipmunk", .chipmunk),
        ("fox", .fox), ("coyote", .coyote), ("turtle", .turtle), ("tortoise", .turtle),
        ("frog", .frog), ("toad", .frog), ("salamander", .salamander), ("snake", .snake),
        ("bird", .bird), ("cat", .catOrDog), ("dog", .catOrDog),
    ]

    func detect(in pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> AnimalDetection? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
        try? handler.perform([request])
        for observation in request.results ?? [] where observation.confidence >= minimumConfidence {
            let label = observation.identifier.lowercased()
            if let match = keywords.first(where: { label.contains($0.0) }) {
                return AnimalDetection(species: match.1, confidence: observation.confidence)
            }
        }
        return nil
    }
}
