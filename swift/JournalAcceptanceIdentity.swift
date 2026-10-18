#if (os(iOS) && targetEnvironment(simulator)) || JOURNAL_ACCEPTANCE_TESTING
import Darwin
import Foundation

/// Simulator acceptance only. This type is absent from real-device/macOS builds.
/// The private same-user socket carries bounded identity metadata, never commands.
final class JournalAcceptanceServer: @unchecked Sendable {
  typealias Reader = @MainActor @Sendable (String) async -> Data?
  private let path: String
  private let read: Reader
  private let queue = DispatchQueue(label: "journal.acceptance.identity")
  private var listener: Int32 = -1
  private var source: DispatchSourceRead?
  private var active: Int32 = -1
  private var connectionSource: DispatchSourceRead?
  private var requestBuffer = Data()
  private var socketInode: ino_t?

  init(path: String, read: @escaping Reader) { self.path = path; self.read = read }

  static func endpoint(environment: [String: String]) -> String? {
    guard environment["JOURNAL_ACCEPTANCE"] == "1",
          let udid = environment["SIMULATOR_UDID"], UUID(uuidString: udid) != nil else { return nil }
    return "/tmp/lj-identity-\(geteuid())-\(udid.lowercased())/identity.sock"
  }

  private func address() throws -> sockaddr_un {
    var value = sockaddr_un()
    value.sun_family = sa_family_t(AF_UNIX)
    guard path.utf8.count < MemoryLayout.size(ofValue: value.sun_path) else { throw Failure.unavailable }
    value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &value.sun_path) { bytes in
      bytes.initializeMemory(as: UInt8.self, repeating: 0)
      bytes.copyBytes(from: path.utf8)
    }
    return value
  }

  enum Failure: Error { case unavailable }

  func start() throws {
    try queue.sync {
      let directory = (path as NSString).deletingLastPathComponent
      var info = stat()
      if lstat(directory, &info) != 0 {
        guard errno == ENOENT, mkdir(directory, 0o700) == 0 else { throw Failure.unavailable }
        guard lstat(directory, &info) == 0 else { throw Failure.unavailable }
      }
      guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(),
            info.st_mode & 0o777 == 0o700 else { throw Failure.unavailable }
      var address = try address()
      if lstat(path, &info) == 0 {
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid() else { throw Failure.unavailable }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw Failure.unavailable }
        _ = fcntl(probe, F_SETFL, O_NONBLOCK)
        let result = withUnsafePointer(to: &address) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        let refused = errno == ECONNREFUSED
        close(probe)
        guard result != 0, refused, unlink(path) == 0 else { throw Failure.unavailable }
      } else if errno != ENOENT { throw Failure.unavailable }
      let fd = socket(AF_UNIX, SOCK_STREAM, 0)
      guard fd >= 0 else { throw Failure.unavailable }
      var noSignal: Int32 = 1
      _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
      let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
      }
      guard bound == 0 else { close(fd); throw Failure.unavailable }
      guard chmod(path, 0o600) == 0, listen(fd, 2) == 0, lstat(path, &info) == 0 else {
        close(fd); unlink(path); throw Failure.unavailable
      }
      socketInode = info.st_ino
      guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { close(fd); unlink(path); throw Failure.unavailable }
      listener = fd
      let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
      source.setEventHandler { [weak self] in self?.receive() }
      source.setCancelHandler { close(fd) }
      self.source = source
      source.resume()
    }
  }

  func stop() {
    queue.sync {
      source?.cancel(); source = nil
      listener = -1 // the listener cancellation handler owns close
      if let connectionSource {
        connectionSource.cancel() // its cancellation handler owns the read fd
      } else if active >= 0 { close(active) } // unmonitored reply duplicate
      connectionSource = nil; active = -1
      activeTicket = nil; requestBuffer = Data()
      var info = stat()
      if let inode = socketInode, lstat(path, &info) == 0, info.st_ino == inode { unlink(path) }
      socketInode = nil
    }
  }

  private func receive() {
    let fd = accept(listener, nil, nil)
    guard fd >= 0 else { return }
    guard active < 0 else { close(fd); return }
    var uid: uid_t = 0, gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { close(fd); return }
    var noSignal: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { close(fd); return }
    active = fd
    let ticket = UUID()
    activeTicket = ticket
    requestBuffer = Data()
    let connection = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    connection.setEventHandler { [weak self] in self?.readRequest(fd, ticket: ticket) }
    connection.setCancelHandler { close(fd) }
    connectionSource = connection
    connection.resume()
    // Absolute deadline: byte trickles cannot reset it or block stop().
    queue.asyncAfter(deadline: .now() + 1) { [weak self] in
      guard let self, self.connectionSource != nil else { return }
      self.finish(fd, ticket: ticket, data: nil)
    }
  }

  private func readRequest(_ fd: Int32, ticket: UUID) {
    guard active == fd, activeTicket == ticket else { return }
    var bytes = [UInt8](repeating: 0, count: 1025)
    while requestBuffer.count <= 1024 {
      let count = recv(fd, &bytes, min(bytes.count, 1025 - requestBuffer.count), 0)
      if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
      guard count > 0 else { finish(fd, ticket: ticket, data: nil); return }
      requestBuffer.append(contentsOf: bytes.prefix(count))
      if requestBuffer.contains(10) { break }
    }
    guard requestBuffer.count <= 1024, requestBuffer.last == 10,
          let object = try? JSONSerialization.jsonObject(with: requestBuffer) as? [String: Any],
          Set(object.keys) == ["schema_version", "challenge"],
          let schema = object["schema_version"] as? Int, schema == 1,
          let challenge = object["challenge"] as? String, UUID(uuidString: challenge) != nil else {
      finish(fd, ticket: ticket, data: nil); return
    }
    // libdispatch owns the monitored read descriptor until cancellation completes.
    // A duplicate keeps the connected socket alive for the asynchronous reply.
    let replyFD = dup(fd)
    guard replyFD >= 0 else { finish(fd, ticket: ticket, data: nil); return }
    connectionSource?.cancel(); connectionSource = nil
    active = replyFD; requestBuffer = Data()
    queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.finish(replyFD, ticket: ticket, data: nil) }
    Task { @MainActor [weak self, read] in
      let reply = await read(challenge)
      self?.queue.async { [weak self] in self?.finish(replyFD, ticket: ticket, data: reply) }
    }
  }

  private var activeTicket: UUID?
  private func finish(_ fd: Int32, ticket: UUID, data: Data?) {
    guard active == fd, activeTicket == ticket else { return }
    active = -1; activeTicket = nil
    let monitored = connectionSource
    connectionSource = nil; requestBuffer = Data()
    // If still parsing, cancel only after the current handler has sent its fixed
    // rejection; close occurs exactly once in the source cancellation handler.
    defer { if let monitored { monitored.cancel() } else { close(fd) } }
    var reply = data ?? Data("{\"status\":\"unavailable\"}".utf8)
    guard reply.count <= 4096 else { return }
    reply.append(10)
    reply.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = send(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
        if count <= 0 { break }
        offset += count
      }
    }
  }
}
#endif

#if os(iOS) && targetEnvironment(simulator)
import UIKit

/// Two native display ticks allow one complete presentation turn after the
/// source/patch observation. Timeout or any intervening identity change blocks.
@MainActor final class JournalAcceptanceDisplayBarrier: NSObject {
  private var continuation: CheckedContinuation<Bool, Never>?
  private var link: CADisplayLink?
  private var ticks = 0
  static func wait() async -> Bool {
    await withCheckedContinuation { continuation in
      let barrier = JournalAcceptanceDisplayBarrier()
      barrier.continuation = continuation
      let link = CADisplayLink(target: barrier, selector: #selector(advance))
      barrier.link = link
      link.add(to: .main, forMode: .common)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak barrier] in barrier?.finish(false) }
    }
  }
  @objc private func advance() { ticks += 1; if ticks >= 2 { finish(true) } }
  private func finish(_ accepted: Bool) {
    guard let continuation else { return }
    self.continuation = nil
    link?.invalidate(); link = nil
    continuation.resume(returning: accepted)
  }
}
#endif
