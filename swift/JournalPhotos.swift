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
        PHPhotoLibrary.shared().performChanges {
          let request = PHAssetCreationRequest.forAsset()
          let options = PHAssetResourceCreationOptions()
          options.shouldMoveFile = false
          request.addResource(with: .photo, fileURL: url, options: options)
        } completionHandler: { success, _ in
          Task { @MainActor in completion(success) }
        }
      },
      feedback: feedback)
  }
}
#endif
