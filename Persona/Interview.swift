import UniformTypeIdentifiers

/// The create walkthrough's questions. Muse Wonder turns the answers into a name, a portrait,
/// and two or three traits, so each question asks about style, not facts.
enum Interview {
    struct Question {
        let prompt: String
        let options: [String]
        let placeholder: String
    }

    static let questions = [
        Question(prompt: "When you bring it a problem, it should…",
                 options: ["Get straight to the point", "Cheer you on", "Argue with you a little", "Turn it into a story"],
                 placeholder: "Or say it your way"),
        Question(prompt: "Its energy is…",
                 options: ["Calm and unhurried", "Bouncy and excited", "Dry and deadpan", "Big and theatrical"],
                 placeholder: "Or say it your way"),
        Question(prompt: "It treats you like…",
                 options: ["Royalty", "Its best friend", "Its apprentice", "A worthy rival"],
                 placeholder: "Or say it your way"),
        Question(prompt: "It helps you with…",
                 options: ["Work and focus", "Writing", "Learning new things", "Workouts", "Cooking", "Big decisions"],
                 placeholder: "Or something else"),
        Question(prompt: "Anything else? A quirk, an obsession, a catchphrase.",
                 options: [],
                 placeholder: "Secretly obsessed with birds"),
    ]
}

extension UTType {
    /// A shared persona: JSON with the vectors and portrait inside. Declared in Info.plist.
    static let persona = UTType(exportedAs: "dev.persona.file", conformingTo: .json)
}
