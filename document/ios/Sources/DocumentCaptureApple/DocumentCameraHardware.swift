import Foundation

public struct DocumentCameraCapability: Codable, Equatable, Sendable {
  public enum Lens: String, Codable, Sendable {
    case wide
    case ultraWide
    case telephoto
    case dualWide
    case triple
  }

  public let lens: Lens
  public let localizedName: String
  public let minimumFocusDistanceMillimeters: Int?
  public let maximumPhotoWidth: Int
  public let maximumPhotoHeight: Int
  public let videoFieldOfViewDegrees: Float
  public let lensAperture: Float
  public let supportsContinuousAutoFocus: Bool
  public let supportsFocusPointOfInterest: Bool

  public var maximumPhotoPixelCount: Int64 {
    Int64(maximumPhotoWidth) * Int64(maximumPhotoHeight)
  }
}

public struct DocumentCameraHardwareSelection: Codable, Equatable, Sendable {
  public enum Reason: String, Codable, Sendable {
    case virtualDualWidePreferred
    case virtualTriplePreferred
    case explicitlyRequested
    case physicalFallback
    // Historical values remain decodable in retained reports.
    case highResolutionPhysicalCamera
    case wideMeetsWorkingDistance
    case wideFocusDistanceUnknown
    case wideRequiresLongerWorkingDistance
    case ultraWideRequiredForWorkingDistance
  }

  public let selected: DocumentCameraCapability
  public let discovered: [DocumentCameraCapability]
  public let reason: Reason
  public let targetWorkingDistanceMillimeters: Int?
}

struct DocumentCameraCandidate: Equatable, Sendable {
  let identifier: String
  let capability: DocumentCameraCapability
}

struct DocumentCameraSelectionPolicy: Sendable {
  func select(
    from candidates: [DocumentCameraCandidate]
  ) -> (candidate: DocumentCameraCandidate, report: DocumentCameraHardwareSelection)? {
    for lens in [DocumentCameraCapability.Lens.dualWide, .triple, .wide, .ultraWide, .telephoto] {
      guard let selected = ranked(candidates, lens: lens).first else { continue }
      let reason: DocumentCameraHardwareSelection.Reason
      switch lens {
      case .dualWide: reason = .virtualDualWidePreferred
      case .triple: reason = .virtualTriplePreferred
      default: reason = .physicalFallback
      }
      return (
        selected,
        DocumentCameraHardwareSelection(
          selected: selected.capability,
          discovered: candidates.sorted { $0.identifier < $1.identifier }.map(\.capability),
          reason: reason, targetWorkingDistanceMillimeters: nil)
      )
    }
    return nil
  }

  private func ranked(
    _ candidates: [DocumentCameraCandidate],
    lens: DocumentCameraCapability.Lens
  ) -> [DocumentCameraCandidate] {
    candidates
      .filter { $0.capability.lens == lens }
      .sorted {
        if $0.capability.maximumPhotoPixelCount != $1.capability.maximumPhotoPixelCount {
          return $0.capability.maximumPhotoPixelCount > $1.capability.maximumPhotoPixelCount
        }
        return $0.identifier < $1.identifier
      }
  }
}
