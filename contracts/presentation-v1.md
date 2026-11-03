# Presentation demonstration contract v1

This contract is implemented in the optional `presentation/` Swift package and matching plain Kotlin source. It governs reference-app workflow behavior, not capability evidence, biometric scores, credential authentication, permission grants or identity acceptance. No capability implementation is extracted by this change. A successful demonstration produces `StubOutcome(scope: demonstrationOnly)`, visibly identified through catalog keys in every state. A backend or capability must never consume it as evidence.

## Ownership and API

Plain single-owner controllers own transitions, enabled actions, localized message keys, step selection and engine orchestration. Native renderers receive immutable `WorkflowState` and forward each prepared action's typed event. State contains no service client, mutable runtime or evidence bytes. Controllers are synchronous and not thread-safe: hosts and engine callbacks must use the same serialized executor. Platform hosts translate lifecycle callbacks into `interrupt`/`restore` events; renderers do not decide recovery. Hosts subscribe to Swift `onStateChange` / Kotlin `onStateChanged` to receive immutable snapshots after each state replacement, including delayed engine completions. The observer runs on the same serialized executor; ignored events and stale/duplicate completions publish nothing. Initial rendering reads `state` explicitly. Hosts detach the observer and cancel an active controller before discarding or replacing its session; observer callbacks must not initiate reentrant workflow events.

`Capability` selects one demonstration sequence:

| Capability | Ordered step identifiers |
| --- | --- |
| biometric | referencePortrait, selfie, compare |
| document | front, back, review |
| passport | mrz, nfc, review |

These sequences are workflow placeholders. They do not claim live cameras, complete optical document authentication, MRZ validation, NFC access protocols, passport trust, face inference or PAD. Reference portraits and all results remain synthetic absence markers; no real sample is loaded.

`OperationRequest` v1 contains the capability, prepared step resource key and token `(capability, sessionID, generation, step)`. `WorkflowEngine.resolve` is the injectable **demonstration** port. `DeterministicStubEngine` synchronously returns configured `observed` or `recoverable(reason)` completion; tests inject a deferred engine to exercise delayed callbacks. Its result has no production observation payload. Future capability adapters require separately versioned evidence contracts that retain source/model/policy lineage; changing this stub port into a production authorization API is forbidden.

## State and event semantics

| Current state | Accepted event | Result |
| --- | --- | --- |
| idle | start | ready at first step, generation advances |
| ready | advance | capturing |
| capturing | advance | processing with a fresh step/generation-bound token |
| processing | advance | submit current request once to selected engine |
| processing | matching observed completion | next step ready; last step produces demonstration-only completion |
| ready, capturing, processing | fail(reason), interrupt, simulateFailure | recoverable, advance generation, discard pending request |
| recoverable | retry | ready at same step, advance generation |
| recoverable due to interruption | restore | ready at same step, advance generation |
| ready, capturing, processing, recoverable | cancel | terminal cancelled, advance generation, discard pending request |
| completed, cancelled | any event | unchanged |

Other events are ignored. Completion is accepted only in processing when its entire token exactly matches the pending token. Duplicate, prior-attempt, wrong-step, other-session and post-cancel completions cannot change state. A replacement session must have a unique session identifier; default controllers generate independent UUIDs. Deterministic tests may inject a fixed non-secret session ID. The controller submits at most once for each token even when processing receives duplicate advance events. It invalidates state before forwarding `cancel(token)` to the engine on cancellation or interruption/failure, so a synchronous completion during engine cancellation is already stale. The deterministic stub has no external work to stop; real adapters must implement their own resource cancellation and remain subject to separate integration tests.

Recoverable reasons are `permissionDenied`, `interrupted`, `serviceUnavailable` and `invalidInput`. Unavailable engines produce no observation or completion outcome. The UI's simulate-failure action models `serviceUnavailable`; it never invokes a real provider. Permission denial is a simulated typed event, not an operating-system permission check. Idle is initial readiness; processing explicitly exposes pending work. No initial loader is fabricated because this scaffold loads no models or persistent session.

`restore` resumes an interrupted **in-memory** journey, restarting its current step. It does not claim durable restoration, checkpoint storage, recovered NFC sessions or resumption of an invalidated operation. Completed and cancelled controllers require a newly constructed controller for a new session. There are no timers, ambient I/O, persistence, consent processing, retained personal data or automatic retries.

## Localization and accessibility

Controllers emit keys only. Capability title, current step, phase, recovery reason, every action, permanent stub notice and scoped outcome each have separate catalog keys. `accessibilityStatusKey` selects a recovery reason when present, otherwise the phase. Renderers resolve keys using generated native resources and expose semantic status; announcements, focus and native assistive-technology acceptance are separate integration responsibilities.

## Conformance vectors and compatibility

[presentation-v1.vectors.tsv](presentation-v1.vectors.tsv) is a UTF-8 tab-separated fixture with a mandatory header and seven columns: `id`, `capability`, `events`, `phases`, `steps`, `generations`, `reasons`. Each of the last five columns is an equal-length comma-separated sequence with one expected state after every event. `-` denotes no recovery reason. Step indexes are zero-based. Generations are nonnegative counters, incremented on start, invalidation, recovery and transition to a new step. They are presentation counters, not clocks, proof counters or security nonces; overflow is outside this bounded synthetic demo's supported lifetime.

Fixture events use the public event names. `fail:<reason>` carries a reason. `complete:current` uses the current pending token, `complete:saved` replays the first pending token, `complete:foreign` substitutes another session, `complete:wrongStep` increments the step, `complete:wrongCapability` substitutes another capability, and `complete:invalidInput` returns a recoverable invalid-input completion. Test drivers keep the saved token independently of controller state. Swift and Kotlin consume this exact shared file; 11 vectors cover all three completed sequences plus invalid order, duplicate start/completion, cancellation, wrong bindings, denial, unavailable operation, invalid input and interruption/restoration. Separate engine tests exercise delayed callbacks and repeated submissions.

This is an in-process API, not a JSON or BFF encoding. No unknown serialized fields are accepted and no wire decoder is supplied. Enum additions and changes to transitions, message keys, token binding or outcome scope require contract/version review, fixture updates and both platform suites. SDK capability public APIs remain separate.
