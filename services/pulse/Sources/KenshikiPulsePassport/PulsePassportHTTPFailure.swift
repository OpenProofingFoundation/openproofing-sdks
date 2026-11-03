import Foundation

/// Exact HTTP classification without retaining arbitrary server prose or response bytes.
public struct PulsePassportHTTPFailure: Error, Equatable, Sendable {
  public let statusCode:Int
  public let code:String?
  public let reason:String?
  public let classification:PulsePassportFailure
  public init(statusCode:Int,code:String?,reason:String?,classification:PulsePassportFailure) {
    self.statusCode=statusCode;self.code=code;self.reason=reason;self.classification=classification
  }
}

/// A platform key refusal bound to the exact installation/key that produced it.
public struct PulsePassportKeyFailure: Error, Sendable {
  public let installationID:String
  public let keyID:String
  public let underlyingError:Error
  public init(installationID:String,keyID:String,underlyingError:Error) {
    self.installationID=installationID;self.keyID=keyID;self.underlyingError=underlyingError
  }
}
