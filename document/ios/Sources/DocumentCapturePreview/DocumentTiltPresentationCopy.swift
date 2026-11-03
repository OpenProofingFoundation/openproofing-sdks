import DocumentCaptureApple

/// Optional sample presentation. Hosts may supply their own copy and animations.
extension DocumentTiltPresentation {
  public var illustratedEdge: IllustratedEdge {
    switch phase {
    case .leftEdgeCloser: .left
    case .rightEdgeCloser: .right
    default: .none
    }
  }

  /// Fixed illustration cue only. This is not a measured or requested physical angle.
  public var demonstrationRotationDegrees: Double {
    switch phase {
    case .leftEdgeCloser: 18
    case .rightEdgeCloser: -18
    default: 0
    }
  }

  public var progress: Double {
    switch phase {
    case .baseline: 0
    case .leftEdgeCloser: 0.2
    case .neutralAfterLeft: 0.4
    case .rightEdgeCloser: 0.6
    case .neutralAfterRight: 0.8
    case .readyForStill: 1
    case .skipped, .cancelled, .evidenceLimit: 0
    }
  }

}
