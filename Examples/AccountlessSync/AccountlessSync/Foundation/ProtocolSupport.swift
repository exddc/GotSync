import Foundation
import GotSync

enum DemoEndpoints {
    static let invitationURLScheme = "accountless-sync"
    static let relayURL = URL(string: "ws://127.0.0.1:8765/v1")!
    static let mailboxURL = URL(string: "http://127.0.0.1:8767/v1/mailbox")!
    static var policy: EndpointSecurityPolicy {
        #if DEBUG
        .localDevelopment
        #else
        .production
        #endif
    }
}

extension SyncEndpointConfiguration {
    func replacingRelayURL(_ relayURL: URL) throws -> SyncEndpointConfiguration {
        try SyncEndpointConfiguration(relayURL: relayURL, mailboxURL: mailboxURL, policy: DemoEndpoints.policy)
    }

    static let relayInfoKey = "GotSyncRelayURL"
    static let mailboxInfoKey = "GotSyncMailboxURL"

    static func load(
        bundle: Bundle = .main,
        policy: EndpointSecurityPolicy = DemoEndpoints.policy
    ) throws -> SyncEndpointConfiguration {
        try load(
            values: [
                relayInfoKey: bundle.object(
                    forInfoDictionaryKey: relayInfoKey
                ) as? String,
                mailboxInfoKey: bundle.object(
                    forInfoDictionaryKey: mailboxInfoKey
                ) as? String,
            ].compactMapValues { $0 },
            policy: policy,
            applyDeveloperOverrides: true
        )
    }

    static func load(
        values: [String: String],
        policy: EndpointSecurityPolicy,
        applyDeveloperOverrides: Bool = false
    ) throws -> SyncEndpointConfiguration {
        var relayURL = try configuredURL(
            values[relayInfoKey],
            key: relayInfoKey,
            fallback: DemoEndpoints.relayURL,
            invalid: .invalidRelay,
            policy: policy
        )
        #if DEBUG
        if applyDeveloperOverrides,
           let override = DeveloperEndpointPreferences.relayURLOverride
        {
            try validateRelayURL(override, policy: policy)
            relayURL = override
        }
        #endif
        let mailboxURL = try configuredURL(
            values[mailboxInfoKey],
            key: mailboxInfoKey,
            fallback: DemoEndpoints.mailboxURL,
            invalid: .invalidMailbox,
            policy: policy
        )
        return try SyncEndpointConfiguration(
            relayURL: relayURL,
            mailboxURL: mailboxURL,
            policy: policy
        )
    }

    private static func configuredURL(
        _ rawValue: String?,
        key: String,
        fallback: URL,
        invalid: SyncEndpointConfigurationError,
        policy: EndpointSecurityPolicy
    ) throws -> URL {
        let value = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let value, !value.isEmpty, !value.contains("$(") {
            guard let url = URL(string: value) else {
                throw invalid
            }
            return url
        }
        guard policy == .localDevelopment else {
            throw SyncEndpointConfigurationError.missing(key)
        }
        return fallback
    }

}
