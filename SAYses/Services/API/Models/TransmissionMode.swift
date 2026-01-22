import Foundation

enum TransmissionMode: String, CaseIterable {
    case voiceActivity = "voice_activity"
    case pushToTalk = "push_to_talk"
    case continuous = "continuous"

    var displayName: String {
        switch self {
        case .voiceActivity:
            return "Sprachaktivität"
        case .pushToTalk:
            return "Push-to-Talk"
        case .continuous:
            return "Ständig an"
        }
    }

    var description: String {
        switch self {
        case .voiceActivity:
            return "Automatische Erkennung wenn Sie sprechen"
        case .pushToTalk:
            return "Halten Sie den Button gedrückt zum Sprechen"
        case .continuous:
            return "Mikrofon ist immer aktiv"
        }
    }
}
