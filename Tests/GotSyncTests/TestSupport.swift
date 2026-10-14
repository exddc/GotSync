import Foundation
@testable import GotSync

final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    init(service: String = UUID().uuidString) {}
    func read(account: String) throws -> Data? { lock.withLock { values[account] } }
    func write(_ data: Data, account: String) throws { lock.withLock { values[account] = data } }
    func delete(account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}

enum TestEndpoints {
    static let relayURL = URL(string: "ws://127.0.0.1:8765/v1")!
    static let mailboxURL = URL(string: "http://127.0.0.1:8767/v1/mailbox")!
}

@MainActor
extension SyncEngine {
    convenience init(
        keychain: any SecretStore = MemorySecretStore(),
        baseDirectory: URL? = nil,
        relayURL: URL = TestEndpoints.relayURL,
        mailboxURL: URL = TestEndpoints.mailboxURL,
        mailboxTransport: (any MailboxTransport)? = nil,
        backgroundMailboxScheduler: (any BackgroundMailboxScheduling)? = nil,
        pairingRetryDelayNanoseconds: UInt64 = 1_000_000_000
    ) {
        let directory = baseDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = try! SyncConfiguration(relayURL: relayURL, mailboxURL: mailboxURL, storageDirectory: directory, invitationURLScheme: "gotsync-tests", endpointPolicy: .localDevelopment)
        self.init(configuration: configuration, secretStore: keychain, mailboxTransport: mailboxTransport, backgroundMailboxScheduler: backgroundMailboxScheduler, pairingRetryDelayNanoseconds: pairingRetryDelayNanoseconds)
    }
}

@MainActor
final class RecordingBackgroundMailboxScheduler: BackgroundMailboxScheduling {
    private(set) var scheduleCalls: [Int] = []
    private(set) var cancelCount = 0
    private(set) var isRegistered = false
    var handler: (@MainActor () async -> Void)?
    func register(handler: @escaping @MainActor () async -> Void) { self.handler = handler; isRegistered = true }
    func scheduleFlushIfNeeded(pendingOperationCount: Int) { scheduleCalls.append(pendingOperationCount); if pendingOperationCount <= 0 { cancelCount += 1 } }
    func cancelFlush() { cancelCount += 1 }
    func fireHandlerForTesting() async { await handler?() }
}
