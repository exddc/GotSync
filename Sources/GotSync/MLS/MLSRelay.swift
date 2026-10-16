import Foundation

struct MLSDescriptor: Codable, Equatable, Sendable {
  let clientID: Data
  let fingerprint: String
  let keyPackage: Data
  var transportHash: Data? = nil
}

struct MLSPairReference: Codable, Equatable, Sendable {
  let route: String
  let token: Data
  let keyPackage: Data
  let member: String
  let transportHash: Data
  var welcome: Data
}

struct MLSEvent: Codable, Equatable, Sendable {
  let kind: String
  let epoch: UInt64
  let payload: Data
  var previous: UInt64? = nil
  var pair: MLSPairReference? = nil
  var cursor: UInt64? = nil
  var remove: [String]? = nil

  var id: String {
    var copy = self
    copy.cursor = nil
    return (try! CanonicalJSON.encoder.encode(copy)).sha256.hexString
  }
}

struct MLSWelcome: Codable, Sendable {
  let payload: Data
  let group: String
  let cursor: UInt64
  let epoch: UInt64
}

struct MLSRelayReply: Decodable, Sendable {
  var expired: Bool? = nil
  var ready: Bool? = nil
  var capacity: Bool? = nil
  var canAppend: Bool? = nil
  var accepted: Bool? = nil
  var cursor: UInt64? = nil
  var events: [MLSEvent]? = nil
  var host: MLSDescriptor? = nil
  var joiner: MLSDescriptor? = nil
  var approved: Bool? = nil
  var welcome: MLSWelcome? = nil
}

struct MLSRelayRequest: Encodable, Sendable {
  let version = 3
  let operation: String
  let route: String
  let token: Data
  var member: String? = nil
  var descriptor: MLSDescriptor? = nil
  var cursor: UInt64? = nil
  var id: String? = nil
  var event: MLSEvent? = nil
}

protocol MLSDelivery: Sendable {
  func request(_ request: MLSRelayRequest) async throws -> MLSRelayReply
}

private final class NoMLSRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

struct MLSRelay: MLSDelivery {
  let url: URL
  let policy: EndpointSecurityPolicy

  func request(_ request: MLSRelayRequest) async throws -> MLSRelayReply {
    guard
      url.scheme == "https"
        || (policy == .localDevelopment && url.scheme == "http"
          && ["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""))
    else {
      throw SyncError.privateSyncUnreachable
    }
    var message = URLRequest(url: url)
    message.httpMethod = "POST"
    message.timeoutInterval = 10
    message.setValue("application/json", forHTTPHeaderField: "Content-Type")
    message.httpBody = try CanonicalJSON.encoder.encode(request)
    guard message.httpBody!.count <= 512 * 1024 else { throw SyncError.archiveTooLarge }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForResource = 15
    let session = URLSession(
      configuration: configuration, delegate: NoMLSRedirects(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(for: message)
    var data = Data()
    for try await byte in bytes {
      guard data.count < 8 * 1024 * 1024 else { throw SyncError.invalidSyncMessage }
      data.append(byte)
    }
    guard let response = response as? HTTPURLResponse else {
      throw SyncError.privateSyncUnreachable
    }
    if response.statusCode == 400 {
      struct Rejection: Decodable { let error: String }
      let code = try? CanonicalJSON.decoder.decode(Rejection.self, from: data).error
      if code == "expired"
        || (code == "unauthorized" && ["welcome", "join", "pair"].contains(request.operation))
      {
        throw SyncError.invitationExpired
      }
      if code == "historyUnavailable" || code == "unauthorized" {
        throw SyncError.invalidCredentials
      }
    }
    guard response.statusCode == 200 else { throw SyncError.privateSyncUnreachable }
    return try CanonicalJSON.decoder.decode(MLSRelayReply.self, from: data)
  }
}
