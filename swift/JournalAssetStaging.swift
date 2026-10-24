import Foundation
import OSLog

actor JournalAssetStaging {
  static let shared = JournalAssetStaging()

  nonisolated static func discard(_ file: URL) {
    do { try FileManager.default.removeItem(at: file) }
    catch let error as CocoaError where error.code == .fileNoSuchFile { } // Idempotent cleanup.
    catch {
      let reason = JournalAssetDiagnostic.classify(error, stage: .cleanup)
      Logger(subsystem: "com.logseq.journal", category: "cleanup")
        .error("Temporary attachment cleanup could not finish (assetImport.cleanup.failed; \(reason.description, privacy: .public))")
    }
  }

  func copy(_ source: URL) -> Result<URL, JournalAssetDiagnostic> {
    let scoped = source.startAccessingSecurityScopedResource()
    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
    let ext = source.pathExtension.lowercased()
    let name = "journal-import-" + UUID().uuidString.lowercased() + (ext.isEmpty ? "" : "." + ext)
    let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    do { try FileManager.default.copyItem(at: source, to: dest); return .success(dest) }
    catch { Self.discard(dest); return .failure(.classify(error, stage: .fileCopy)) }
  }

  func write(_ data: Data, ext: String) -> Result<URL, JournalAssetDiagnostic> {
    let dest = FileManager.default.temporaryDirectory.appendingPathComponent("journal-import-" + UUID().uuidString.lowercased() + "." + ext)
    do { try data.write(to: dest); return .success(dest) }
    catch { Self.discard(dest); return .failure(.classify(error, stage: .stageWrite)) }
  }
}
