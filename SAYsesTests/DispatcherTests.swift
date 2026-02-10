import XCTest
@testable import SAYses

final class DispatcherTests: XCTestCase {

    // MARK: - ActiveDispatcherCallResponse JSON Decoding

    func testActiveDispatcherCallResponse_activeCall() throws {
        let json = """
        {"active": true, "request_id": "abc-123", "handled_by_user_name": "dispatcher_max", \
        "handled_by_user_displayname": "Dispatcher Max", "mumble_channel_id": 42}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(ActiveDispatcherCallResponse.self, from: json)
        XCTAssertTrue(response.active)
        XCTAssertEqual(response.requestId, "abc-123")
        XCTAssertEqual(response.handledByUserName, "dispatcher_max")
        XCTAssertEqual(response.handledByUserDisplayname, "Dispatcher Max")
        XCTAssertEqual(response.mumbleChannelId, 42)
    }

    func testActiveDispatcherCallResponse_noActiveCall() throws {
        let json = """
        {"active": false}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(ActiveDispatcherCallResponse.self, from: json)
        XCTAssertFalse(response.active)
        XCTAssertNil(response.requestId)
        XCTAssertNil(response.handledByUserName)
        XCTAssertNil(response.handledByUserDisplayname)
        XCTAssertNil(response.mumbleChannelId)
    }

    func testActiveDispatcherCallResponse_partialFields() throws {
        let json = """
        {"active": true, "request_id": "xyz", "mumble_channel_id": 7}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(ActiveDispatcherCallResponse.self, from: json)
        XCTAssertTrue(response.active)
        XCTAssertEqual(response.requestId, "xyz")
        XCTAssertNil(response.handledByUserName)
        XCTAssertNil(response.handledByUserDisplayname)
        XCTAssertEqual(response.mumbleChannelId, 7)
    }

    // MARK: - evaluatePresence State Machine

    func testPresence_bothInChannel_fromIdle_setsInProgress() {
        let action = MumbleService.evaluatePresence(
            dispatcherInChannel: true,
            localUserInChannel: true,
            currentStatus: .idle
        )
        XCTAssertEqual(action, .setInProgress)
    }

    func testPresence_bothInChannel_alreadyInProgress_noChange() {
        let action = MumbleService.evaluatePresence(
            dispatcherInChannel: true,
            localUserInChannel: true,
            currentStatus: .inProgress
        )
        XCTAssertEqual(action, .noChange)
    }

    func testPresence_dispatcherMissing_whileInProgress_startsTimer() {
        let action = MumbleService.evaluatePresence(
            dispatcherInChannel: false,
            localUserInChannel: true,
            currentStatus: .inProgress
        )
        XCTAssertEqual(action, .startTimer)
    }

    func testPresence_localUserMissing_whileInProgress_startsTimer() {
        let action = MumbleService.evaluatePresence(
            dispatcherInChannel: true,
            localUserInChannel: false,
            currentStatus: .inProgress
        )
        XCTAssertEqual(action, .startTimer)
    }

    func testPresence_bothMissing_whileInProgress_startsTimer() {
        let action = MumbleService.evaluatePresence(
            dispatcherInChannel: false,
            localUserInChannel: false,
            currentStatus: .inProgress
        )
        XCTAssertEqual(action, .startTimer)
    }

    func testPresence_dispatcherMissing_whileIdle_noChange() {
        let action = MumbleService.evaluatePresence(
            dispatcherInChannel: false,
            localUserInChannel: true,
            currentStatus: .idle
        )
        XCTAssertEqual(action, .noChange)
    }

    func testPresence_bothMissing_whileIdle_noChange() {
        let action = MumbleService.evaluatePresence(
            dispatcherInChannel: false,
            localUserInChannel: false,
            currentStatus: .idle
        )
        XCTAssertEqual(action, .noChange)
    }

    func testPresence_bothMissing_whileInterrupted_noChange() {
        let action = MumbleService.evaluatePresence(
            dispatcherInChannel: false,
            localUserInChannel: false,
            currentStatus: .interrupted
        )
        XCTAssertEqual(action, .noChange)
    }

    func testPresence_bothReturn_whileInterrupted_setsInProgress() {
        let action = MumbleService.evaluatePresence(
            dispatcherInChannel: true,
            localUserInChannel: true,
            currentStatus: .interrupted
        )
        XCTAssertEqual(action, .setInProgress)
    }

    func testPresence_dispatcherMissing_whileInterrupted_noChange() {
        let action = MumbleService.evaluatePresence(
            dispatcherInChannel: false,
            localUserInChannel: true,
            currentStatus: .interrupted
        )
        XCTAssertEqual(action, .noChange)
    }

    func testPresence_onlyDispatcher_whileIdle_noChange() {
        let action = MumbleService.evaluatePresence(
            dispatcherInChannel: true,
            localUserInChannel: false,
            currentStatus: .idle
        )
        XCTAssertEqual(action, .noChange)
    }
}
