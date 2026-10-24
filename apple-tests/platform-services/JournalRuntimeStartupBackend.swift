import Foundation

public enum LUIBackendError: Error { case invalidBatch(String) }
public struct LUIEvent: Sendable {}
public struct LUIAppleExtensionRegistry { public init() {} }
@MainActor public final class LUIAppleBackend {
  public var rootIDs: [Int] = []
  public var onEvent: ((LUIEvent) -> Void)?
  public init(appIcons: [String: String], extensionRegistry: LUIAppleExtensionRegistry) throws {}
  public func apply(json: String) throws {
    if json == "invalid" { throw NSError(domain: "fixture", code: 1) }
    rootIDs = [42]
  }
}
