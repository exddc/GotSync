import Foundation

public struct SyncConfiguration: Sendable {
    public let endpoints: SyncEndpointConfiguration
    public let endpointPolicy: EndpointSecurityPolicy
    public let storageDirectory: URL
    public let invitationURLScheme: String

    public init(relayURL: URL, mailboxURL: URL, storageDirectory: URL, invitationURLScheme: String, endpointPolicy: EndpointSecurityPolicy = .production) throws {
        try Invitation.validateURLScheme(invitationURLScheme)
        self.invitationURLScheme = invitationURLScheme.lowercased()
        endpoints = try SyncEndpointConfiguration(relayURL: relayURL, mailboxURL: mailboxURL, policy: endpointPolicy)
        self.endpointPolicy = endpointPolicy
        self.storageDirectory = storageDirectory
    }
}

enum SyncTiming {
    static let invitationTimeToLive: TimeInterval = 15 * 60
    static let invitationTimeToLiveNanoseconds: UInt64 = 900_000_000_000
    static let savingNoticeDelay: TimeInterval = 2
    static let linkCompleteCelebrationDuration: TimeInterval = 2.4
}

@MainActor
public protocol BackgroundMailboxScheduling: AnyObject {
    func register(handler: @escaping @MainActor () async -> Void)
    func scheduleFlushIfNeeded(pendingOperationCount: Int)
    func cancelFlush()
}

@MainActor
final class NoopBackgroundMailboxScheduler: BackgroundMailboxScheduling {
    func register(handler: @escaping @MainActor () async -> Void) {}
    func scheduleFlushIfNeeded(pendingOperationCount: Int) {}
    func cancelFlush() {}
}
