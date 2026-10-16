import Foundation

struct WireDatabaseSalt: Sendable {
  let secrets: any SecretStore
  private static let account = "wire-mls-v3-database-salt"

  #if os(iOS)
    private struct Record: Codable {
      let salt: Data
      var paths: [String]
    }
    private var wire: KeychainStore { KeychainStore(service: "wire.com") }
    private func account(_ path: URL) -> String {
      "keystore_salt_" + Data(path.path.utf8).sha256.hexString
    }
    private func record() throws -> Record? {
      try secrets.read(account: Self.account).map {
        try CanonicalJSON.decoder.decode(Record.self, from: $0)
      }
    }
    private func save(_ record: Record) throws {
      try secrets.write(CanonicalJSON.encoder.encode(record), account: Self.account)
    }
  #endif

  func prepare(_ path: URL) throws {
    #if os(iOS)
      if var record = try record() {
        guard record.salt.count == 16, record.salt != Data("SQLite format 3\0".utf8) else {
          throw SyncError.invalidCredentials
        }
        try wire.write(record.salt, account: account(path))
        if !record.paths.contains(path.path) {
          record.paths.append(path.path)
          try save(record)
        }
      } else if FileManager.default.fileExists(atPath: path.path) {
        throw SyncError.invalidCredentials
      }
    #endif
  }

  func capture(_ path: URL) throws {
    #if os(iOS)
      if try record() == nil {
        guard let salt = try wire.read(account: account(path)), salt.count == 16,
          salt != Data("SQLite format 3\0".utf8)
        else { throw SyncError.invalidCredentials }
        try save(Record(salt: salt, paths: [path.path]))
      }
    #endif
  }

  func remove(_ path: URL) throws {
    #if os(iOS)
      try wire.delete(account: account(path))
      if var record = try record() {
        record.paths.removeAll { $0 == path.path }
        try save(record)
      }
    #endif
  }

  func retain(_ paths: Set<String>) throws {
    #if os(iOS)
      guard var record = try record() else { return }
      for path in record.paths where !paths.contains(path) {
        try wire.delete(account: account(URL(fileURLWithPath: path)))
      }
      record.paths.removeAll { !paths.contains($0) }
      try save(record)
    #endif
  }

  func removeAll() throws {
    #if os(iOS)
      for path in try record()?.paths ?? [] {
        try wire.delete(account: account(URL(fileURLWithPath: path)))
      }
      try secrets.delete(account: Self.account)
    #endif
  }
}
