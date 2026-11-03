import BiometricCapture
import Testing


@MainActor
@Suite struct SelfieCapturePresentationTests {
  @Test func reopeningTheSameEvidenceAttemptHasANewCameraIdentity() {
    let state = SelfieCapturePresentationState()
    let first = state.open()
    state.close()
    let second = state.open()
    #expect(first.id != second.id)
    #expect(state.current == second)
  }

  @Test func outgoingCallbacksCannotAffectTheReplacementCamera() {
    let state = SelfieCapturePresentationState()
    let first = state.open()
    state.close()
    let second = state.open()
    var events: [String] = []
    for event in ["captured", "failed", "dismissed"] {
      state.receive(from: first.id) {
        events.append(event)
        state.close()
      }
    }
    #expect(events.isEmpty)
    #expect(state.current == second)
    state.receive(from: second.id) { events.append("current") }
    #expect(events == ["current"])
  }

  @Test func processingRetiresDuplicateAndLateCameraCallbacks() {
    let state = SelfieCapturePresentationState()
    let presentation = state.open()
    var captures = 0
    state.receive(from: presentation.id) {
      captures += 1
      state.close()
    }
    state.receive(from: presentation.id) { captures += 1 }
    var dismissed = false
    state.receive(from: presentation.id) { dismissed = true }
    #expect(captures == 1)
    #expect(!dismissed)
    #expect(state.current == nil)
  }

}
