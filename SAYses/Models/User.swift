import Foundation

struct User: Identifiable, Hashable {
    let session: UInt32
    let channelId: UInt32
    let name: String
    let isMuted: Bool
    let isDeafened: Bool
    let isSelfMuted: Bool
    let isSelfDeafened: Bool
    let isSuppressed: Bool

    var id: UInt32 { session }

    init(session: UInt32 = 0, channelId: UInt32 = 0, name: String, isMuted: Bool = false, isDeafened: Bool = false, isSelfMuted: Bool = false, isSelfDeafened: Bool = false, isSuppressed: Bool = false) {
        self.session = session
        self.channelId = channelId
        self.name = name
        self.isMuted = isMuted
        self.isDeafened = isDeafened
        self.isSelfMuted = isSelfMuted
        self.isSelfDeafened = isSelfDeafened
        self.isSuppressed = isSuppressed
    }

    var displayStatus: String {
        if isDeafened || isSelfDeafened {
            return "Stumm & Taub"
        } else if isMuted || isSelfMuted {
            return "Stumm"
        } else if isSuppressed {
            return "Unterdrückt"
        }
        return ""
    }
}
