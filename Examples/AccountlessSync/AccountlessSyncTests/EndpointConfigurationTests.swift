import XCTest
@testable import AccountlessSync
@testable import GotSync

final class EndpointConfigurationTests: XCTestCase {
    func testDeveloperRelayReplacementUsesDemoPolicy() throws {
        let original = try SyncEndpointConfiguration.load(values: [:], policy: .localDevelopment)
        let replacement = try original.replacingRelayURL(URL(string: "ws://192.168.1.10:8765/v2/pairing")!)
        XCTAssertEqual(replacement.relayURL.host, "192.168.1.10")
        XCTAssertEqual(replacement.mailboxURL, original.mailboxURL)
    }

    func testDebugFallsBackToLoopbackEndpoints() throws {
        let configuration = try SyncEndpointConfiguration.load(
            values: [:],
            policy: .localDevelopment
        )

        XCTAssertEqual(configuration.relayURL, DemoEndpoints.relayURL)
        XCTAssertEqual(configuration.mailboxURL, DemoEndpoints.mailboxURL)
    }

    func testProductionRequiresBothEndpoints() {
        XCTAssertThrowsError(
            try SyncEndpointConfiguration.load(
                values: [:],
                policy: .production
            )
        ) {
            XCTAssertEqual(
                $0 as? SyncEndpointConfigurationError,
                .missing(SyncEndpointConfiguration.relayInfoKey)
            )
        }
    }

    func testProductionAcceptsSecureNonLoopbackEndpoints() throws {
        let configuration = try SyncEndpointConfiguration.load(
            values: [
                SyncEndpointConfiguration.relayInfoKey:
                    "wss://sync.example.com/v2/pairing",
                SyncEndpointConfiguration.mailboxInfoKey:
                    "https://sync.example.com/v2/mls",
            ],
            policy: .production
        )

        XCTAssertEqual(
            configuration.relayURL.absoluteString,
            "wss://sync.example.com/v2/pairing"
        )
        XCTAssertEqual(
            configuration.mailboxURL.absoluteString,
            "https://sync.example.com/v2/mls"
        )
    }

    func testProductionRejectsInsecureLoopbackAndMalformedEndpoints() {
        let invalidPairs = [
            (
                "ws://sync.example.com/v2/pairing",
                "https://sync.example.com/v2/mls"
            ),
            (
                "wss://127.0.0.1/v2/pairing",
                "https://sync.example.com/v2/mls"
            ),
            (
                "wss://0.0.0.0/v2/pairing",
                "https://sync.example.com/v2/mls"
            ),
            (
                "wss://sync.example.com/wrong",
                "https://sync.example.com/v2/mls"
            ),
            (
                "wss://sync.example.com/v2/pairing?token=secret",
                "https://sync.example.com/v2/mls"
            ),
            (
                "wss://sync.example.com/v2/pairing",
                "http://sync.example.com/v2/mls"
            ),
            (
                "wss://sync.example.com/v2/pairing",
                "https://localhost/v2/mls"
            ),
            (
                "wss://sync.example.com/v2/pairing",
                "https://sync.example.com/wrong"
            ),
            (
                "wss://sync.example.com/v1",
                "https://sync.example.com/v2/mls"
            ),
            (
                "wss://sync.example.com/v2/pairing",
                "https://sync.example.com/v1/mailbox"
            ),
        ]

        for pair in invalidPairs {
            XCTAssertThrowsError(
                try SyncEndpointConfiguration.load(
                    values: [
                        SyncEndpointConfiguration.relayInfoKey: pair.0,
                        SyncEndpointConfiguration.mailboxInfoKey: pair.1,
                    ],
                    policy: .production
                ),
                "\(pair)"
            )
        }
    }

    func testProductionRejectsUnresolvedBuildSetting() {
        XCTAssertThrowsError(
            try SyncEndpointConfiguration.load(
                values: [
                    SyncEndpointConfiguration.relayInfoKey:
                        "$(GOTSYNC_RELAY_URL)",
                    SyncEndpointConfiguration.mailboxInfoKey:
                        "https://sync.example.com/v2/mls",
                ],
                policy: .production
            )
        ) {
            XCTAssertEqual(
                $0 as? SyncEndpointConfigurationError,
                .missing(SyncEndpointConfiguration.relayInfoKey)
            )
        }
    }

    func testConfiguredMalformedEndpointDoesNotUseDebugFallback() {
        XCTAssertThrowsError(
            try SyncEndpointConfiguration.load(
                values: [
                    SyncEndpointConfiguration.relayInfoKey: "://",
                    SyncEndpointConfiguration.mailboxInfoKey:
                        "http://127.0.0.1:8767/v2/mls",
                ],
                policy: .localDevelopment
            )
        ) {
            XCTAssertEqual(
                $0 as? SyncEndpointConfigurationError,
                .invalidRelay
            )
        }
    }

    func testLocalDevelopmentAcceptsPrivateLANPlaintextEndpoints() throws {
        let configuration = try SyncEndpointConfiguration.load(
            values: [
                SyncEndpointConfiguration.relayInfoKey:
                    "ws://192.168.1.10:8765/v2/pairing",
                SyncEndpointConfiguration.mailboxInfoKey:
                    "http://192.168.1.10:8767/v2/mls",
            ],
            policy: .localDevelopment
        )

        XCTAssertEqual(
            configuration.relayURL.absoluteString,
            "ws://192.168.1.10:8765/v2/pairing"
        )
        XCTAssertEqual(
            configuration.mailboxURL.absoluteString,
            "http://192.168.1.10:8767/v2/mls"
        )
    }

    func testLocalDevelopmentRejectsPublicPlaintextEndpoints() {
        XCTAssertThrowsError(
            try SyncEndpointConfiguration.load(
                values: [
                    SyncEndpointConfiguration.relayInfoKey:
                        "ws://sync.example.com/v2/pairing",
                    SyncEndpointConfiguration.mailboxInfoKey:
                        "http://sync.example.com/v2/mls",
                ],
                policy: .localDevelopment
            )
        ) {
            XCTAssertEqual(
                $0 as? SyncEndpointConfigurationError,
                .invalidRelay
            )
        }
    }
}
