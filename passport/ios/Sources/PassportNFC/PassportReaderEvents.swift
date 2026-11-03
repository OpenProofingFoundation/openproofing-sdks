import Foundation
import PassportSDK

#if os(iOS)
  import CoreNFC
  @preconcurrency import NFCPassportReader

  /// Maps transport events into the host-owned vocabulary and suppresses vendor diagnostics.
  enum PassportReaderEvents {
    static func event(_ message: NFCViewDisplayMessage) -> PassportReadEvent {
      switch message {
      case .requestPresentPassport: .presenting
      case .authenticatingWithPassport(let progress): .authenticating(progress: progress)
      case .readingDataGroupProgress(let group, let progress):
        .reading(group: group.getName(), progress: progress)
      case .activeAuthentication: .activeAuthentication
      // A vendor "successful read" message precedes CoreNFC teardown. Only read() above emits
      // transportComplete after its invalidation callback releases the continuation.
      case .successfulRead: .transportFinishing
      case .error(let error): .failure(failure(error))
      }
    }

    static func failure(_ error: Error) -> PassportReadFailure {
      if let failure = error as? PassportReadFailure { return failure }
      if error is CancellationError { return .cancelled }
      if let error = error as? NFCPassportReaderError {
        switch error {
        case .UserCanceled: return .cancelled
        case .InvalidMRZKey: return .invalidAccessKey
        case .NFCNotSupported: return .unsupported
        case .ReaderAlreadyInUse: return .busy
        case .NoConnectedTag, .ConnectionError, .TimeOutError: return .connectionLost
        case .MoreThanOneTagFound: return .multipleTags
        case .TagNotValid: return .invalidTag
        case .Unknown(let underlying): return failure(underlying)
        default: return .readFailed
        }
      }
      if let error = error as? NFCReaderError {
        switch error.code {
        case .readerSessionInvalidationErrorUserCanceled: return .cancelled
        case .readerSessionInvalidationErrorSessionTimeout,
          .readerTransceiveErrorSessionInvalidated, .readerTransceiveErrorTagConnectionLost,
          .readerTransceiveErrorTagResponseError, .readerTransceiveErrorRetryExceeded,
          .readerTransceiveErrorTagNotConnected:
          return .connectionLost
        default: return .readFailed
        }
      }
      return .readFailed
    }

  }
#endif
