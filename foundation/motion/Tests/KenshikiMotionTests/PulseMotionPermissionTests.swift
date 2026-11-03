import XCTest
@testable import KenshikiMotion

final class PulseMotionPermissionTests: XCTestCase {
    @MainActor
    func testCancellationWhileRequestingPreventsQueryRegistration() {
        var queries = 0
        var states: [PulseMotionPermission.Status] = []
        let permission = PulseMotionPermission(status: { .notRequested }, query: { _ in queries += 1 })
        permission.request { state in
            states.append(state)
            permission.cancel()
        }
        XCTAssertEqual(states, [.requesting])
        XCTAssertEqual(queries, 0)
    }

    @MainActor
    func testCancelledAndReplacedQueriesCannotPublishLateResults() throws {
        var status = PulseMotionPermission.Status.notRequested
        var callbacks: [@MainActor @Sendable () -> Void] = []
        var states: [PulseMotionPermission.Status] = []
        let permission = PulseMotionPermission(status: { status }, query: { callbacks.append($0) })
        permission.request { states.append($0) }
        permission.cancel()
        status = .authorized
        try XCTUnwrap(callbacks.first)()
        XCTAssertEqual(states, [.requesting])

        status = .notRequested
        permission.request { states.append($0) }
        permission.request { states.append($0) }
        status = .denied
        callbacks[1]()
        XCTAssertEqual(states, [.requesting, .requesting, .requesting])
        callbacks[2]()
        XCTAssertEqual(states, [.requesting, .requesting, .requesting, .denied])
    }

    @MainActor
    func testResolvedPermissionReturnsImmediatelyWithoutQuery() {
        for status in [PulseMotionPermission.Status.authorized, .denied, .unavailable] {
            var states: [PulseMotionPermission.Status] = []
            var queries = 0
            let permission = PulseMotionPermission(status: { status }, query: { _ in queries += 1 })
            permission.request { states.append($0) }
            XCTAssertEqual(states, [status])
            XCTAssertEqual(queries, 0)
        }
    }
}
