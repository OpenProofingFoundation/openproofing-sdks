import Foundation

public enum Capability: String, CaseIterable, Sendable {
    case biometric, document, passport

    public var titleKey: String { "capability.\(rawValue).title" }

    fileprivate var steps: [String] {
        switch self {
        case .biometric: ["referencePortrait", "selfie", "compare"]
        case .document: ["front", "back", "review"]
        case .passport: ["mrz", "nfc", "review"]
        }
    }
}

public enum WorkflowPhase: String, Sendable {
    case idle, ready, capturing, processing, recoverable, completed, cancelled
}

public enum RecoveryReason: String, Sendable {
    case permissionDenied, interrupted, serviceUnavailable, invalidInput
    public var messageKey: String { "workflow.reason.\(rawValue)" }
}

public struct OperationToken: Equatable, Sendable {
    public let capability: Capability
    public let sessionID: String
    public let generation: Int
    public let step: Int

    public init(capability: Capability, sessionID: String, generation: Int, step: Int) {
        self.capability = capability
        self.sessionID = sessionID
        self.generation = generation
        self.step = step
    }
}

public enum StubCompletion: Equatable, Sendable {
    case observed
    case recoverable(RecoveryReason)
}

public struct OperationRequest: Equatable, Sendable {
    public let contractVersion: Int = 1
    public let capability: Capability
    public let stepKey: String
    public let token: OperationToken
}

/// Optional presentation demonstration port, not a capability evidence or authorization API.
/// Implementations deliver callbacks on the same serialized executor as the controller.
public protocol WorkflowEngine {
    func resolve(_ request: OperationRequest, completion: @escaping (OperationToken, StubCompletion) -> Void)
    func cancel(_ token: OperationToken)
}

public struct DeterministicStubEngine: WorkflowEngine {
    private let result: StubCompletion
    public init(result: StubCompletion = .observed) { self.result = result }
    public func resolve(_ request: OperationRequest, completion: @escaping (OperationToken, StubCompletion) -> Void) {
        completion(request.token, result)
    }
    public func cancel(_: OperationToken) { /* Stub has no external operation to stop. */ }
}

public enum WorkflowEvent: Equatable, Sendable {
    case start, advance, retry, cancel, interrupt, restore, simulateFailure
    case fail(RecoveryReason)
    case complete(OperationToken, StubCompletion)
}

public enum WorkflowActionID: String, Sendable {
    case start, advance, retry, cancel, restore, simulateFailure
}

public struct WorkflowAction: Equatable, Sendable {
    public let id: WorkflowActionID
    public let labelKey: String
    public let event: WorkflowEvent
    public let enabled: Bool

    fileprivate init(_ id: WorkflowActionID, event: WorkflowEvent) {
        self.id = id
        self.labelKey = "workflow.action.\(id.rawValue)"
        self.event = event
        self.enabled = true
    }
}

public enum StubScope: String, Sendable { case demonstrationOnly }

/// A demonstration outcome carries no image, credential, model verdict or identity decision.
public struct StubOutcome: Equatable, Sendable {
    public let capability: Capability
    public let scope: StubScope = .demonstrationOnly
    public let messageKey: String = "workflow.stub.outcome"
}

public struct WorkflowState: Equatable, Sendable {
    public let capability: Capability
    public let phase: WorkflowPhase
    public let step: Int
    public let generation: Int
    public let stepKey: String
    public let messageKey: String
    public let reason: RecoveryReason?
    public let actions: [WorkflowAction]
    public let pendingOperation: OperationToken?
    public let outcome: StubOutcome?
    public let stubNoticeKey: String = "workflow.stub.notice"
    public var accessibilityStatusKey: String { reason?.messageKey ?? messageKey }
}

/// Single-owner synchronous controller. Platform hosts serialize events on their UI executor.
/// No sensors, inference, storage, platform permission or network operations are performed.
public final class WorkflowController {
    public private(set) var state: WorkflowState
    public var onStateChange: ((WorkflowState) -> Void)?
    private let sessionID: String
    private let engine: any WorkflowEngine
    private var submitted: OperationToken?

    public init(capability: Capability, sessionID: String = UUID().uuidString,
                engine: any WorkflowEngine = DeterministicStubEngine()) {
        self.sessionID = sessionID
        self.engine = engine
        state = Self.makeState(capability, .idle, step: 0, generation: 0)
    }

    public func send(_ event: WorkflowEvent) {
        switch event {
        case .start:
            guard state.phase == .idle else { return }
            replace(.ready, generation: state.generation + 1)
        case .advance:
            advance()
        case .retry:
            guard state.phase == .recoverable else { return }
            replace(.ready, generation: state.generation + 1)
        case .cancel:
            guard [.ready, .capturing, .processing, .recoverable].contains(state.phase) else { return }
            invalidate(.cancelled)
        case .interrupt:
            fail(.interrupted)
        case .restore:
            guard state.phase == .recoverable, state.reason == .interrupted else { return }
            replace(.ready, generation: state.generation + 1)
        case .simulateFailure:
            fail(.serviceUnavailable)
        case .fail(let reason):
            fail(reason)
        case .complete(let token, let completion):
            complete(token, completion)
        }
    }

    private func advance() {
        switch state.phase {
        case .ready:
            replace(.capturing)
        case .capturing:
            let token = OperationToken(capability: state.capability, sessionID: sessionID,
                                       generation: state.generation, step: state.step)
            replace(.processing, pending: token)
        case .processing:
            guard let token = state.pendingOperation, submitted != token else { return }
            submitted = token
            let request = OperationRequest(capability: state.capability, stepKey: state.stepKey, token: token)
            engine.resolve(request) { [weak self] token, completion in self?.complete(token, completion) }
        default:
            break
        }
    }

    private func fail(_ reason: RecoveryReason) {
        guard [.ready, .capturing, .processing].contains(state.phase) else { return }
        invalidate(.recoverable, reason: reason)
    }

    private func invalidate(_ phase: WorkflowPhase, reason: RecoveryReason? = nil) {
        let pending = state.pendingOperation
        replace(phase, generation: state.generation + 1, reason: reason)
        if let pending { engine.cancel(pending) }
    }

    private func complete(_ token: OperationToken, _ completion: StubCompletion) {
        guard state.phase == .processing, token == state.pendingOperation else { return }
        switch completion {
        case .recoverable(let reason):
            fail(reason)
        case .observed:
            let next = state.step + 1
            if next < state.capability.steps.count {
                replace(.ready, step: next, generation: state.generation + 1)
            } else {
                replace(.completed, outcome: StubOutcome(capability: state.capability))
            }
        }
    }

    private func replace(
        _ phase: WorkflowPhase, step: Int? = nil, generation: Int? = nil,
        reason: RecoveryReason? = nil, pending: OperationToken? = nil, outcome: StubOutcome? = nil
    ) {
        state = Self.makeState(state.capability, phase, step: step ?? state.step,
                               generation: generation ?? state.generation, reason: reason,
                               pending: pending, outcome: outcome)
        onStateChange?(state)
    }

    private static func makeState(
        _ capability: Capability, _ phase: WorkflowPhase, step: Int, generation: Int,
        reason: RecoveryReason? = nil, pending: OperationToken? = nil, outcome: StubOutcome? = nil
    ) -> WorkflowState {
        WorkflowState(capability: capability, phase: phase, step: step, generation: generation,
                      stepKey: "workflow.step.\(capability.rawValue).\(capability.steps[step])",
                      messageKey: "workflow.phase.\(phase.rawValue)", reason: reason,
                      actions: actions(phase, reason), pendingOperation: pending, outcome: outcome)
    }

    private static func actions(_ phase: WorkflowPhase, _ reason: RecoveryReason?) -> [WorkflowAction] {
        switch phase {
        case .idle:
            [WorkflowAction(.start, event: .start)]
        case .ready, .capturing, .processing:
            [WorkflowAction(.advance, event: .advance), WorkflowAction(.cancel, event: .cancel),
             WorkflowAction(.simulateFailure, event: .simulateFailure)]
        case .recoverable:
            reason == .interrupted
                ? [WorkflowAction(.restore, event: .restore), WorkflowAction(.cancel, event: .cancel)]
                : [WorkflowAction(.retry, event: .retry), WorkflowAction(.cancel, event: .cancel)]
        case .completed, .cancelled:
            []
        }
    }
}
