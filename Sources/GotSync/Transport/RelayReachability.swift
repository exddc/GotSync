import Foundation

public enum RelaySocket {
  public static func probeReachability(url: URL, policy: EndpointSecurityPolicy = .production) async
    -> Bool
  {
    guard (try? SyncEndpointConfiguration.validateRelayURL(url, policy: policy)) != nil else {
      return false
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 5
    let session = URLSession(configuration: configuration)
    let socket = session.webSocketTask(with: url)
    defer {
      socket.cancel(with: .goingAway, reason: nil)
      session.invalidateAndCancel()
    }
    socket.resume()
    do {
      let route = try Data.secureRandom(count: 32).base64URLString
      let body = try JSONSerialization.data(withJSONObject: [
        "type": "register", "version": 1, "route": route,
      ])
      try await socket.send(.string(String(decoding: body, as: UTF8.self)))
      return true
    } catch { return false }
  }
}
