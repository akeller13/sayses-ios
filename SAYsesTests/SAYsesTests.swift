import XCTest
@testable import SAYses

final class SAYsesTests: XCTestCase {

    func testChannelHierarchy() throws {
        let channels = [
            Channel(id: 1, parentId: 0, name: "Root", position: 0, subChannels: []),
            Channel(id: 2, parentId: 1, name: "Sub 1", position: 0, subChannels: []),
            Channel(id: 3, parentId: 1, name: "Sub 2", position: 1, subChannels: [])
        ]

        let hierarchy = Channel.buildHierarchy(from: channels)
        XCTAssertEqual(hierarchy.count, 1)
        XCTAssertEqual(hierarchy.first?.name, "Root")
    }

    func testUserDisplayStatus() throws {
        let mutedUser = User(
            session: 1,
            channelId: 1,
            name: "Test",
            isMuted: true,
            isDeafened: false,
            isSelfMuted: false,
            isSelfDeafened: false,
            isSuppressed: false
        )
        XCTAssertEqual(mutedUser.displayStatus, "Stumm")
    }
}
