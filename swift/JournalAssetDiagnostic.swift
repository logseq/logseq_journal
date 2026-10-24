import Foundation

/// Only finite operation-owned vocabulary crosses attachment feedback boundaries.
struct JournalAssetDiagnostic: Error, Equatable, Sendable, CustomStringConvertible {
  enum Stage: String, Sendable {
    case fileSelection = "file-selection", fileCopy = "file-copy", photoLoad = "photo-load"
    case stageWrite = "stage-write", photoStage = "photo-stage", photoWrite = "photo-write"
    case cameraEncode = "camera-encode", selection, cleanup
  }
  enum Category: String, Sendable {
    case permissionDenied = "permission-denied", sourceUnavailable = "source-unavailable"
    case noSpace = "no-space", cancelled, providerUnavailable = "provider-unavailable"
    case dataUnavailable = "data-unavailable", selectionLimit = "selection-limit", failed
    case libraryUnavailable = "library-unavailable", networkRequired = "network-required"
    case networkFailed = "network-failed", unsupported, interrupted, restricted
    case invalidResource = "invalid-resource", ambiguousSource = "ambiguous-source"
    case historyUnavailable = "history-unavailable", internalFailure = "internal-failure"
  }
  let stage: Stage
  let category: Category
  var description: String { "\(stage.rawValue).\(category.rawValue)" }

  static func classify(_ error: any Error, stage: Stage) -> Self {
    if let diagnostic = error as? Self { return diagnostic }
    let native = error as NSError
    let category: Category
    if native.domain == NSCocoaErrorDomain {
      switch native.code {
      case NSUserCancelledError: category = .cancelled
      case CocoaError.fileReadNoPermission.rawValue, CocoaError.fileWriteNoPermission.rawValue:
        category = .permissionDenied
      case CocoaError.fileReadNoSuchFile.rawValue, CocoaError.fileNoSuchFile.rawValue:
        category = .sourceUnavailable
      case CocoaError.fileWriteOutOfSpace.rawValue: category = .noSpace
      default: category = stage == .photoLoad ? .providerUnavailable : .failed
      }
    } else if native.domain == NSPOSIXErrorDomain {
      switch native.code {
      case Int(POSIXError.EACCES.rawValue), Int(POSIXError.EPERM.rawValue): category = .permissionDenied
      case Int(POSIXError.ENOENT.rawValue): category = .sourceUnavailable
      case Int(POSIXError.ENOSPC.rawValue): category = .noSpace
      default: category = .failed
      }
    } else if native.domain == "PHPhotosErrorDomain" {
      // Finite SDK PHPhotosError codes only; no Photos identifiers/userInfo escape.
      switch native.code {
      case -1: category = .internalFailure
      case 3072: category = .cancelled
      case 3114, 3142, 3143: category = .libraryUnavailable
      case 3164: category = .networkRequired
      case 3169: category = .networkFailed
      case 3201, 3303: category = .sourceUnavailable
      case 3202: category = .ambiguousSource
      case 3300, 3306, 5423: category = .unsupported
      case 3301: category = .interrupted
      case 3302: category = .invalidResource
      case 3305: category = .noSpace
      case 3307: category = .selectionLimit
      case 3310: category = .restricted
      case 3311: category = .permissionDenied
      case 3105, 3210: category = .historyUnavailable
      default: category = .failed
      }
    } else { category = stage == .photoLoad ? .providerUnavailable : .failed }
    return Self(stage: stage, category: category)
  }

  static func summary(_ failures: [Self]) -> String? {
    guard !failures.isEmpty else { return nil }
    let counts = Dictionary(grouping: failures, by: \.description)
      .map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: ", ")
    return "\(failures.count) selected item(s) could not be added. Your other attachments are kept. (\(counts))"
  }
}
