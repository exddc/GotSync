import XCTest
@testable import GotDoneRelay

final class EndpointConfigurationTests: XCTestCase {
    func testDebugFallsBackToLoopbackEndpoints() throws {
        let configuration = try SyncEndpointConfiguration.load(
            values: [:],
            policy: .localDevelopment
        )

        XCTAssertEqual(configuration.relayURL, SyncProtocol.defaultRelayURL)
        XCTAssertEqual(configuration.mailboxURL, SyncProtocol.defaultMailboxURL)
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
                    "wss://sync.example.com/v1",
                SyncEndpointConfiguration.mailboxInfoKey:
                    "https://sync.example.com/v1/mailbox",
            ],
            policy: .production
        )

        XCTAssertEqual(
            configuration.relayURL.absoluteString,
            "wss://sync.example.com/v1"
        )
        XCTAssertEqual(
            configuration.mailboxURL.absoluteString,
            "https://sync.example.com/v1/mailbox"
        )
    }

    func testProductionRejectsInsecureLoopbackAndMalformedEndpoints() {
        let invalidPairs = [
            (
                "ws://sync.example.com/v1",
                "https://sync.example.com/v1/mailbox"
            ),
            (
                "wss://127.0.0.1/v1",
                "https://sync.example.com/v1/mailbox"
            ),
            (
                "wss://0.0.0.0/v1",
                "https://sync.example.com/v1/mailbox"
            ),
            (
                "wss://sync.example.com/wrong",
                "https://sync.example.com/v1/mailbox"
            ),
            (
                "wss://sync.example.com/v1?token=secret",
                "https://sync.example.com/v1/mailbox"
            ),
            (
                "wss://sync.example.com/v1",
                "http://sync.example.com/v1/mailbox"
            ),
            (
                "wss://sync.example.com/v1",
                "https://localhost/v1/mailbox"
            ),
            (
                "wss://sync.example.com/v1",
                "https://sync.example.com/wrong"
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
                        "$(GOTDONE_RELAY_URL)",
                    SyncEndpointConfiguration.mailboxInfoKey:
                        "https://sync.example.com/v1/mailbox",
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
                        "http://127.0.0.1:8767/v1/mailbox",
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
                    "ws://192.168.178.187:8765/v1",
                SyncEndpointConfiguration.mailboxInfoKey:
                    "http://192.168.178.187:8767/v1/mailbox",
            ],
            policy: .localDevelopment
        )

        XCTAssertEqual(
            configuration.relayURL.absoluteString,
            "ws://192.168.178.187:8765/v1"
        )
        XCTAssertEqual(
            configuration.mailboxURL.absoluteString,
            "http://192.168.178.187:8767/v1/mailbox"
        )
    }

    func testLocalDevelopmentRejectsPublicPlaintextEndpoints() {
        XCTAssertThrowsError(
            try SyncEndpointConfiguration.load(
                values: [
                    SyncEndpointConfiguration.relayInfoKey:
                        "ws://sync.example.com/v1",
                    SyncEndpointConfiguration.mailboxInfoKey:
                        "http://sync.example.com/v1/mailbox",
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
