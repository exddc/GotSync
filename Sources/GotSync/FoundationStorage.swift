import Foundation

enum ProtectedStorage {
  static var directoryAttributes: [FileAttributeKey: Any] {
    var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
    #if os(iOS)
      attributes[.protectionKey] = FileProtectionType.complete
    #endif
    return attributes
  }

  static var fileAttributes: [FileAttributeKey: Any] {
    var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
    #if os(iOS)
      attributes[.protectionKey] = FileProtectionType.complete
    #endif
    return attributes
  }
}

func durableWrite(_ data: Data, to url: URL) throws {
  let temporary = url.deletingLastPathComponent().appendingPathComponent(
    ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
  defer { try? FileManager.default.removeItem(at: temporary) }
  try data.write(to: temporary, options: .withoutOverwriting)
  try FileManager.default.setAttributes(
    ProtectedStorage.fileAttributes, ofItemAtPath: temporary.path)
  try synchronizeFile(temporary)
  guard rename(temporary.path, url.path) == 0 else { throw SyncError.localStorageUnavailable }
  try synchronizeDirectory(url.deletingLastPathComponent())
}

func synchronizeDirectory(_ directory: URL) throws {
  let fd = open(directory.path, O_RDONLY)
  guard fd >= 0 else { throw SyncError.localStorageUnavailable }
  defer { close(fd) }
  guard fsync(fd) == 0 else { throw SyncError.localStorageUnavailable }
}

func synchronizeFile(_ url: URL) throws {
  let handle = try FileHandle(forWritingTo: url)
  defer { try? handle.close() }
  try handle.synchronize()
  guard fcntl(handle.fileDescriptor, F_FULLFSYNC) == 0 else {
    throw SyncError.localStorageUnavailable
  }
}
