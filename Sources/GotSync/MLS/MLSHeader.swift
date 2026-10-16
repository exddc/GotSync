import Foundation

struct MLSHeader {
  static func validate(_ data: Data, group: Data, epoch: UInt64, kind: String) throws {
    var reader = Reader(bytes: Array(data))
    guard try reader.integer(2) == 1 else { throw SyncError.invalidSyncMessage }
    let format = try reader.integer(2)
    guard (kind == "commit" && format == 1) || (kind == "application" && format == 2),
      try reader.vector() == group, try reader.integer(8) == epoch
    else { throw SyncError.invalidSyncMessage }
    if format == 1 {
      guard try reader.integer(1) == 1 else { throw SyncError.invalidSyncMessage }
      _ = try reader.integer(4)
      _ = try reader.vector()
    }
    guard try reader.integer(1) == (kind == "commit" ? 3 : 1) else {
      throw SyncError.invalidSyncMessage
    }
  }

  private struct Reader {
    let bytes: [UInt8]
    var offset = 0
    mutating func integer(_ size: Int) throws -> UInt64 {
      guard offset + size <= bytes.count else { throw SyncError.invalidSyncMessage }
      defer { offset += size }
      return bytes[offset..<offset + size].reduce(0) { ($0 << 8) | UInt64($1) }
    }
    mutating func vector() throws -> Data {
      let first = try integer(1)
      let width = 1 << (first >> 6)
      guard width <= 4 else { throw SyncError.invalidSyncMessage }
      let size = Int(
        ((first & 63) << (8 * (width - 1))) | (width > 1 ? try integer(Int(width - 1)) : 0))
      guard offset + size <= bytes.count else { throw SyncError.invalidSyncMessage }
      defer { offset += size }
      return Data(bytes[offset..<offset + size])
    }
  }
}
