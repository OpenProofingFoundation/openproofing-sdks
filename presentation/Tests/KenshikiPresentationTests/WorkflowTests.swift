import Foundation
import XCTest
@testable import KenshikiPresentation

final class WorkflowTests: XCTestCase {
    func testSharedPositiveAndNegativeVectors() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../contracts/presentation-v1.vectors.tsv").standardized
        let rows = try String(contentsOf: root, encoding: .utf8).split(separator: "\n").dropFirst()
        let catalog = try catalogKeys()
        XCTAssertEqual(rows.count, 11, "Required shared vectors must all execute")
        for row in rows {
            let fields = row.split(separator: "\t").map(String.init)
            XCTAssertEqual(fields.count, 7)
            let capability = try XCTUnwrap(Capability(rawValue: fields[1]))
            let controller = WorkflowController(capability: capability, sessionID: "fixture-session")
            assertCatalog(controller.state, catalog)
            let columns = fields.dropFirst(2).map { $0.split(separator: ",").map(String.init) }
            XCTAssertTrue(columns.allSatisfy { $0.count == columns[0].count })
            var saved: OperationToken?
            for index in columns[0].indices {
                let event = try parse(columns[0][index], controller.state.pendingOperation, saved)
                controller.send(event)
                if saved == nil { saved = controller.state.pendingOperation }
                let state = controller.state
                assertCatalog(state, catalog)
                let context = "\(fields[0]) event \(index): \(columns[0][index])"
                XCTAssertEqual(state.phase.rawValue, columns[1][index], context)
                XCTAssertEqual(state.step, Int(columns[2][index]), context)
                XCTAssertEqual(state.generation, Int(columns[3][index]), context)
                XCTAssertEqual(state.reason?.rawValue ?? "-", columns[4][index], context)
                XCTAssertEqual(state.outcome != nil, state.phase == .completed, context)
                XCTAssertEqual(state.pendingOperation != nil, state.phase == .processing, context)
                XCTAssertEqual(state.capability, capability)
                XCTAssertEqual(state.messageKey, "workflow.phase.\(state.phase.rawValue)")
                if let outcome = state.outcome { XCTAssertEqual(outcome.scope, .demonstrationOnly) }
                if let token = state.pendingOperation {
                    XCTAssertEqual(token.sessionID, "fixture-session")
                    XCTAssertEqual(token.capability, capability)
                    XCTAssertEqual(token.generation, state.generation)
                    XCTAssertEqual(token.step, state.step)
                }
                XCTAssertTrue(state.actions.allSatisfy { $0.enabled })
                XCTAssertEqual(Set(state.actions.map(\.id)).count, state.actions.count)
            }
        }
    }

    func testEveryPresentedActionDispatchesWithoutHiddenViewDecisions() {
        for capability in Capability.allCases {
            let controller = WorkflowController(capability: capability)
            for _ in 0..<10 {
                guard let action = controller.state.actions.first else { break }
                XCTAssertEqual(action.labelKey, "workflow.action.\(action.id.rawValue)")
                controller.send(action.event)
            }
            XCTAssertEqual(controller.state.phase, .completed)
            XCTAssertEqual(controller.state.outcome?.capability, capability)
            XCTAssertTrue(controller.state.actions.isEmpty)
            let completed = controller.state
            [.start, .advance, .retry, .cancel, .interrupt, .restore, .simulateFailure,
             .fail(.invalidInput)].forEach(controller.send)
            XCTAssertEqual(controller.state, completed)
        }
    }

    func testSeparateControllersCannotConsumeOneAnothersCompletion() throws {
        let first = WorkflowController(capability: .biometric)
        let second = WorkflowController(capability: .biometric)
        for controller in [first, second] {
            [.start, .advance, .advance].forEach(controller.send)
        }
        let original = second.state
        second.send(.complete(try XCTUnwrap(first.state.pendingOperation), .observed))
        XCTAssertEqual(second.state, original)
    }

    func testInjectedEngineLateCallbacksAndDuplicateSubmissionsAreFenced() throws {
        let engine = DeferredEngine()
        let controller = WorkflowController(capability: .passport, engine: engine)
        [.start, .advance, .advance, .advance, .advance].forEach(controller.send)
        XCTAssertEqual(engine.requests.count, 1)
        XCTAssertEqual(engine.requests.first?.contractVersion, 1)
        XCTAssertEqual(engine.requests.first?.capability, .passport)
        XCTAssertEqual(engine.requests.first?.stepKey, "workflow.step.passport.mrz")
        controller.send(.interrupt)
        XCTAssertEqual(engine.cancelled.count, 1)
        XCTAssertEqual(controller.state.phase, .recoverable)
        controller.send(.restore)
        [.advance, .advance, .advance].forEach(controller.send)
        XCTAssertEqual(engine.requests.count, 2)
        let before = controller.state
        engine.finish(0)
        XCTAssertEqual(controller.state, before)
        engine.finish(1)
        XCTAssertEqual(controller.state.phase, .ready)
        XCTAssertEqual(controller.state.step, 1)
        let accepted = controller.state
        engine.finish(1)
        XCTAssertEqual(controller.state, accepted)
    }

    func testUnavailableEngineRemainsRecoverableWithoutProducingOutcome() {
        for capability in Capability.allCases {
            let controller = WorkflowController(capability: capability,
                engine: DeterministicStubEngine(result: .recoverable(.serviceUnavailable)))
            [.start, .advance, .advance, .advance].forEach(controller.send)
            XCTAssertEqual(controller.state.phase, .recoverable)
            XCTAssertEqual(controller.state.reason, .serviceUnavailable)
            XCTAssertNil(controller.state.outcome)
            XCTAssertNil(controller.state.pendingOperation)
        }
    }

    func testDeferredCompletionPublishesStateAndIgnoredEventsDoNotNotify() {
        let engine = DeferredEngine()
        let controller = WorkflowController(capability: .document, engine: engine)
        var snapshots: [WorkflowState] = []
        controller.onStateChange = { snapshots.append($0) }
        [.advance, .retry, .restore].forEach(controller.send)
        XCTAssertTrue(snapshots.isEmpty)
        [.start, .advance, .advance, .advance].forEach(controller.send)
        XCTAssertEqual(snapshots.map(\.phase), [.ready, .capturing, .processing])
        engine.finish(0)
        XCTAssertEqual(snapshots.map(\.phase), [.ready, .capturing, .processing, .ready])
        XCTAssertEqual(snapshots.last?.step, 1)
        engine.finish(0)
        XCTAssertEqual(snapshots.count, 4)
        controller.onStateChange = nil
        controller.send(.cancel)
        XCTAssertEqual(snapshots.count, 4)
        XCTAssertEqual(controller.state.phase, .cancelled)
    }

    private func parse(_ text: String, _ current: OperationToken?, _ saved: OperationToken?) throws -> WorkflowEvent {
        let parts = text.split(separator: ":").map(String.init)
        switch parts[0] {
        case "start": return .start
        case "advance": return .advance
        case "retry": return .retry
        case "cancel": return .cancel
        case "interrupt": return .interrupt
        case "restore": return .restore
        case "simulateFailure": return .simulateFailure
        case "fail": return .fail(try XCTUnwrap(RecoveryReason(rawValue: parts[1])))
        case "complete":
            return try completion(parts[1], current, saved)
        default: throw FixtureError.unknownEvent
        }
    }

    private func completion(_ name: String, _ current: OperationToken?, _ saved: OperationToken?) throws -> WorkflowEvent {
        let token = try XCTUnwrap(name == "saved" ? saved : current)
        switch name {
        case "saved", "current": return .complete(token, .observed)
        case "foreign":
            return .complete(OperationToken(capability: token.capability, sessionID: "other-session", generation: token.generation, step: token.step), .observed)
        case "wrongStep":
            return .complete(OperationToken(capability: token.capability, sessionID: token.sessionID, generation: token.generation, step: token.step + 1), .observed)
        case "wrongCapability":
            let other: Capability = token.capability == .passport ? .biometric : .passport
            return .complete(OperationToken(capability: other, sessionID: token.sessionID,
                                             generation: token.generation, step: token.step), .observed)
        case "invalidInput": return .complete(token, .recoverable(.invalidInput))
        default: throw FixtureError.unknownEvent
        }
    }

    private enum FixtureError: Error { case unknownEvent }

    private func catalogKeys() throws -> Set<String> {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../design-system/sources/catalog.jsonc").standardized
        let source = try String(contentsOf: url, encoding: .utf8)
        let json = source.split(separator: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }.joined(separator: "\n")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [String: Any])
        return Set(messages.keys)
    }

    private func assertCatalog(_ state: WorkflowState, _ keys: Set<String>, file: StaticString = #filePath, line: UInt = #line) {
        var emitted = [state.capability.titleKey, state.stepKey, state.messageKey,
                       state.accessibilityStatusKey, state.stubNoticeKey]
        emitted.append(contentsOf: state.actions.map(\.labelKey))
        if let reason = state.reason { emitted.append(reason.messageKey) }
        if let outcome = state.outcome { emitted.append(outcome.messageKey) }
        for key in emitted { XCTAssertTrue(keys.contains(key), "Missing catalog key: \(key)", file: file, line: line) }
    }

    private final class DeferredEngine: WorkflowEngine {
        var requests: [OperationRequest] = []
        var callbacks: [(OperationToken, StubCompletion) -> Void] = []
        var cancelled: [OperationToken] = []
        func resolve(_ request: OperationRequest, completion: @escaping (OperationToken, StubCompletion) -> Void) {
            requests.append(request)
            callbacks.append(completion)
        }
        func finish(_ index: Int) { callbacks[index](requests[index].token, .observed) }
        func cancel(_ token: OperationToken) {
            cancelled.append(token)
            if let index = requests.firstIndex(where: { $0.token == token }) { finish(index) }
        }
    }
}
