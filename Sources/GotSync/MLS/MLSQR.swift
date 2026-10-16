import Foundation

public struct MLSQR: Codable, Sendable {
  let version: Int
  let role: DeviceRole
  let route: String
  let token: Data
  let group: String
  let descriptor: MLSDescriptor
  let expires: Date

  public var isResponse: Bool { role == .joiner }

  init(_ pairing: MLSPairing) {
    version = 3
    role = pairing.role
    route = pairing.route
    token = pairing.token
    group = pairing.group
    descriptor = pairing.local
    expires = pairing.expires
  }

  func url(scheme: String) throws -> URL {
    var parts = URLComponents()
    parts.scheme = scheme
    parts.host = "mls"
    parts.fragment = try CanonicalJSON.encoder.encode(self).base64URLString
    guard let url = parts.url else { throw SyncError.invalidPairMessage }
    return url
  }

  public static func from(url: URL, scheme: String) throws -> MLSQR {
    guard url.scheme == scheme, url.host == "mls", url.query == nil, let fragment = url.fragment,
      fragment.count < 32000
    else { throw SyncError.invalidPairMessage }
    let qr = try CanonicalJSON.decoder.decode(MLSQR.self, from: Data(base64URL: fragment))
    guard qr.version == 3, qr.token.count == 32, qr.expires.timeIntervalSinceNow > -300,
      qr.expires.timeIntervalSinceNow <= 1200,
      UUID(uuidString: qr.group) != nil, UUID(uuidString: qr.route) != nil,
      !qr.descriptor.fingerprint.isEmpty, qr.descriptor.keyPackage.count <= 16384
    else { throw SyncError.invalidPairMessage }
    return qr
  }
}
