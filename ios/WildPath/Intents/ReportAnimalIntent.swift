import AppIntents

extension Species: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Animal"
    static let caseDisplayRepresentations: [Species: DisplayRepresentation] = [
        .deer: "Deer",
        .moose: "Moose",
        .bear: "Bear",
        .raccoon: "Raccoon",
        .skunk: "Skunk",
        .squirrel: "Squirrel",
        .porcupine: "Porcupine",
        .opossum: "Opossum",
        .woodchuck: "Woodchuck",
        .rabbit: "Rabbit",
        .chipmunk: "Chipmunk",
        .fox: "Fox",
        .coyote: "Coyote",
        .turtle: "Turtle",
        .frog: "Frog or toad",
        .salamander: "Salamander",
        .snake: "Snake",
        .bird: "Bird",
        .catOrDog: "Cat or dog",
        .unknown: "Not sure"
    ]
}

/// Hands-free reporting: "Hey Siri, report roadkill in WildPath."
/// Siri then asks which animal, and the report is saved without touching a screen.
struct ReportAnimalIntent: AppIntent {
    static let title: LocalizedStringResource = "Report Animal on Road"
    static let description = IntentDescription("Saves where you saw a dead or injured animal on the road.")
    static let openAppWhenRun = false

    @Parameter(title: "Animal", requestValueDialog: "Which animal?")
    var species: Species

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch await ReportService.shared.report(species, source: .siri) {
        case .saved:
            return .result(dialog: "Got it. \(species.displayName) reported. Thank you.")
        case .duplicate:
            return .result(dialog: "That one was already reported.")
        case .failed(let reason):
            return .result(dialog: "\(reason)")
        }
    }
}

struct WildPathShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ReportAnimalIntent(),
            phrases: [
                "Report roadkill in \(.applicationName)",
                "Report a \(\.$species) in \(.applicationName)",
                "\(.applicationName) report \(\.$species)"
            ],
            shortTitle: "Report Animal",
            systemImageName: "pawprint.fill"
        )
    }
}
