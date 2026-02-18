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

    // MARK: - Channel.canSpeak Permission Tests

    func testCanSpeak_withSpeakPermission_returnsTrue() throws {
        // PERMISSION_SPEAK (0x08) is set
        let channel = Channel(id: 1, name: "Test", permissions: 0x0E) // Traverse + Enter + Speak
        XCTAssertTrue(channel.canSpeak)
    }

    func testCanSpeak_withoutSpeakPermission_returnsFalse() throws {
        // Only Traverse + Enter, NO Speak
        let channel = Channel(id: 1, name: "Test", permissions: 0x06)
        XCTAssertFalse(channel.canSpeak)
    }

    func testCanSpeak_withUnknownPermissions_returnsTrue() throws {
        // permissions == -1 means unknown → default to true
        let channel = Channel(id: 1, name: "Test", permissions: -1)
        XCTAssertTrue(channel.canSpeak)
    }

    func testCanSpeak_withZeroPermissions_returnsFalse() throws {
        // No permissions at all
        let channel = Channel(id: 1, name: "Test", permissions: 0)
        XCTAssertFalse(channel.canSpeak)
    }

    func testCanSpeak_withOnlySpeakPermission_returnsTrue() throws {
        // Only Speak bit set
        let channel = Channel(id: 1, name: "Test", permissions: 0x08)
        XCTAssertTrue(channel.canSpeak)
    }

    // MARK: - ChannelMembersResponse.canSpeak Tests

    func testChannelMembersResponse_decodesCanSpeak() throws {
        let json = """
        {
            "members": [],
            "can_mute": true,
            "can_unmute": false,
            "can_speak": false
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(ChannelMembersResponse.self, from: json)
        XCTAssertFalse(response.canSpeak)
        XCTAssertTrue(response.canMute)
        XCTAssertFalse(response.canUnmute)
    }

    func testChannelMembersResponse_canSpeakDefaultsToTrue() throws {
        // Backend might not send can_speak yet (backwards compatibility)
        let json = """
        {
            "members": [],
            "can_mute": false,
            "can_unmute": false
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(ChannelMembersResponse.self, from: json)
        XCTAssertTrue(response.canSpeak)
    }

    // MARK: - Existing Tests

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
