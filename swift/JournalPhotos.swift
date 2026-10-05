#if os(iOS)
import Photos

@MainActor enum JournalPhotos {
  private static func authorization(_ status: PHAuthorizationStatus) -> JournalPhotoSave.Authorization {
    switch status {
    case .notDetermined: .notDetermined
    case .authorized, .limited: .authorized
    case .denied: .denied
    case .restricted: .restricted
    @unknown default: .restricted
    }
  }

  static func dependencies(feedback: @escaping (JournalPhotoSave.Feedback) -> Void) -> JournalPhotoSave.Dependencies {
    .init(
      authorization: { authorization(PHPhotoLibrary.authorizationStatus(for: .addOnly)) },
      requestAuthorization: { completion in
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
          Task { @MainActor in completion(authorization(status)) }
        }
      },
      stage: JournalPhotoSaveFile.stage,
      write: { url, completion in
        // Photos executes this transaction on its own queue. Explicit
        // Sendable closures prevent inheriting the adapter's MainActor.
        let changes: @Sendable () -> Void = { [url] in
          let request = PHAssetCreationRequest.forAsset()
          let options = PHAssetResourceCreationOptions()
          options.shouldMoveFile = false
          request.addResource(with: .photo, fileURL: url, options: options)
        }
        let finished: @Sendable (Bool, (any Error)?) -> Void = { success, _ in
          Task { @MainActor in completion(success) }
        }
        PHPhotoLibrary.shared().performChanges(changes, completionHandler: finished)
      },
      feedback: feedback)
  }
}
#endif
