import Foundation

/// Every animal a driver can report. Covers the animals most often killed on
/// Vermont roads, from deer and moose to raccoons, skunks, squirrels and frogs.
enum Species: String, Codable, CaseIterable, Identifiable, Sendable {
    // Large animals
    case deer, moose, bear
    // Small and medium mammals
    case raccoon, skunk, squirrel, porcupine, opossum, woodchuck, rabbit, chipmunk, fox, coyote
    // Turtles, frogs and snakes
    case turtle, frog, salamander, snake
    // Birds
    case bird
    // Pets
    case catOrDog
    // Driver couldn't tell at speed
    case unknown

    enum Group: String, CaseIterable, Identifiable {
        case large = "Large animals"
        case mammals = "Small and medium mammals"
        case reptiles = "Turtles, frogs and snakes"
        case birds = "Birds"
        case pets = "Pets"
        case unsure = "Not sure"

        var id: String { rawValue }
    }

    var id: String { rawValue }

    var group: Group {
        switch self {
        case .deer, .moose, .bear: return .large
        case .raccoon, .skunk, .squirrel, .porcupine, .opossum, .woodchuck,
             .rabbit, .chipmunk, .fox, .coyote: return .mammals
        case .turtle, .frog, .salamander, .snake: return .reptiles
        case .bird: return .birds
        case .catOrDog: return .pets
        case .unknown: return .unsure
        }
    }

    var displayName: String {
        switch self {
        case .deer: return "Deer"
        case .moose: return "Moose"
        case .bear: return "Bear"
        case .raccoon: return "Raccoon"
        case .skunk: return "Skunk"
        case .squirrel: return "Squirrel"
        case .porcupine: return "Porcupine"
        case .opossum: return "Opossum"
        case .woodchuck: return "Woodchuck"
        case .rabbit: return "Rabbit"
        case .chipmunk: return "Chipmunk"
        case .fox: return "Fox"
        case .coyote: return "Coyote"
        case .turtle: return "Turtle"
        case .frog: return "Frog or toad"
        case .salamander: return "Salamander"
        case .snake: return "Snake"
        case .bird: return "Bird"
        case .catOrDog: return "Cat or dog"
        case .unknown: return "Not sure"
        }
    }

    /// SF Symbol name. SF Symbols has few wild-animal icons, so most mammals
    /// share the paw print until the app has custom icons.
    var symbol: String {
        switch self {
        case .rabbit: return "hare.fill"
        case .turtle: return "tortoise.fill"
        case .frog, .salamander, .snake: return "lizard.fill"
        case .bird: return "bird.fill"
        case .catOrDog: return "dog.fill"
        case .unknown: return "questionmark.circle.fill"
        default: return "pawprint.fill"
        }
    }

    /// The buttons shown straight away on CarPlay. A CarPlay grid holds at most
    /// 8 buttons, so the eighth is "More animals", which opens the full list.
    /// "Not sure" stays up front because drivers often can't tell at speed.
    static let carPlayQuickPicks: [Species] = [.deer, .moose, .raccoon, .skunk, .squirrel, .turtle, .unknown]

    /// Reports saved by older versions of the app may use names that no longer
    /// exist; read those as "Not sure" instead of failing.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Species(rawValue: raw) ?? .unknown
    }
}
