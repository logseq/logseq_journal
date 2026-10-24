import Foundation

/// A closed vocabulary; associated exception strings never become user text.
enum JournalSafeDiagnostic: String, Error, LocalizedError, Sendable {
  case unknown, missingPayload, typeMismatch, keyNotFound, valueNotFound, dataCorrupted, invalidPayload
  case missingHandler, callbackFailed, allocationFailed, invalidInput, missingRoot
  case startupDecodeFailed, startupWorkerFailed, startupMountFailed
  case invalidStartupConfiguration
  case backendInvalidBatch, backendUnsupportedProperty, backendUnknownNode, backendUnknownExtension
  case backendFingerprintMismatch, backendInvalidHierarchy, backendInvalidEvent, backendRegistryInvalid
  case noSpace, permissionDenied, sourceUnavailable, network, secureStorageUnavailable
  var errorDescription: String? {
    switch self {
    case .unknown: "The native operation could not finish. Retry the operation."
    case .missingPayload: "The required native payload is missing."
    case .typeMismatch: "A native field has an unexpected type."
    case .keyNotFound: "A required native field is missing."
    case .valueNotFound: "A required native value is missing."
    case .dataCorrupted: "The native payload format is invalid."
    case .invalidPayload: "The native payload is unsupported."
    case .missingHandler: "The native runtime callback is not registered. Reopen Journal."
    case .callbackFailed: "The native runtime callback failed. Retry opening Journal."
    case .allocationFailed: "The native runtime could not allocate its response. Reopen Journal."
    case .invalidInput: "The native runtime received an invalid input."
    case .missingRoot: "The native runtime did not provide a root view. Reopen Journal."
    case .startupDecodeFailed: "The native startup configuration could not be decoded. Reopen Journal."
    case .startupWorkerFailed: "The native graph worker could not start. Retry opening Journal."
    case .startupMountFailed: "The native root view could not be mounted. Retry opening Journal."
    case .invalidStartupConfiguration: "The native startup configuration is invalid. Reopen Journal."
    case .backendInvalidBatch: "The native backend rejected the patch or event batch."
    case .backendUnsupportedProperty: "The native backend rejected an unsupported property."
    case .backendUnknownNode: "The native backend could not find the destination node."
    case .backendUnknownExtension: "The native extension is not registered."
    case .backendFingerprintMismatch: "The native extension schema does not match."
    case .backendInvalidHierarchy: "The native node hierarchy is invalid."
    case .backendInvalidEvent: "The native event schema is invalid."
    case .backendRegistryInvalid: "The native extension registry is invalid."
    case .noSpace: "There is not enough storage to finish the operation. Free some space and retry."
    case .permissionDenied: "The native storage operation was denied access. Check access and retry."
    case .sourceUnavailable: "The required local file is unavailable. Retry the operation."
    case .network: "The native operation could not connect. Check your connection and retry."
    case .secureStorageUnavailable: "Secure storage is unavailable. Unlock your device and retry."
    }
  }
  static func classify(_ error: Error) -> Self {
    if let reason = error as? Self { return reason }
    switch error {
    case DecodingError.typeMismatch: return .typeMismatch
    case DecodingError.keyNotFound: return .keyNotFound
    case DecodingError.valueNotFound: return .valueNotFound
    case DecodingError.dataCorrupted: return .dataCorrupted
    case is URLError: return .network
    case let error as CocoaError:
      switch error.code {
      case .fileWriteOutOfSpace: return .noSpace
      case .fileReadNoPermission, .fileWriteNoPermission: return .permissionDenied
      case .fileReadNoSuchFile, .fileNoSuchFile: return .sourceUnavailable
      default: return .unknown
      }
    default:
      return (error as NSError).domain == NSOSStatusErrorDomain ? .secureStorageUnavailable : .unknown
    }
  }
  static func backendBatch(_ source: String) -> Self {
    switch source {
    case "unsupported property", "unsupported property value", "unknown extension property", "unsupported extension property value": .backendUnsupportedProperty
    case "unknown node", "unknown extension node", "unknown parent or child": .backendUnknownNode
    case "unknown extension identifier": .backendUnknownExtension
    case "extension fingerprint mismatch": .backendFingerprintMismatch
    case "child is already attached", "child index is out of bounds", "child insertion would create a cycle", "child is not attached to parent", "cannot drop an attached node": .backendInvalidHierarchy
    case "unknown extension event", "invalid extension event payload", "unknown extension event field", "invalid extension event field", "missing required extension event field": .backendInvalidEvent
    case "extension registry is frozen", "invalid extension identifier", "extension identifier shadows a standard node", "extension identifier is already registered", "invalid extension child identifier", "invalid extension property name", "invalid extension property default", "invalid extension event name", "unknown extension child schema", "duplicate extension property", "duplicate extension event", "duplicate extension event field", "duplicate extension child identifier": .backendRegistryInvalid
    default: .backendInvalidBatch
    }
  }
  static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do { return try JSONDecoder().decode(type, from:data) } catch { throw classify(error) }
  }
}
