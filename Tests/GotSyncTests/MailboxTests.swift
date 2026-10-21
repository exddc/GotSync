import Foundation
import XCTest
@testable import GotSync

final class MailboxTests: XCTestCase {
    func testPairingProvisionMailboxChunksReassemblesAndRetriesExactly()
        throws
    {
        let pairRoot = Data(0..<32)
        let pairID = Data(repeating: 0x11, count: 16)
        let hostDeviceID = Data(repeating: 0x21, count: 16)
        let archive = Data(
            repeating: 0x31,
            count: ProtocolLimits.mailboxEnvelopeBytes + 8_192
        )
        let mailbox = try PairingProvisionMailbox(
            pairRoot: pairRoot,
            pairID: pairID
        )

        let first = try mailbox.seal(
            archive: archive,
            hostDeviceID: hostDeviceID
        )
        let retry = try mailbox.seal(
            archive: archive,
            hostDeviceID: hostDeviceID
        )

        XCTAssertGreaterThan(first.count, 1)
        XCTAssertEqual(first, retry)
        XCTAssertTrue(
            first.allSatisfy {
                $0.ciphertext.count <= ProtocolLimits.mailboxEnvelopeBytes
            }
        )
        XCTAssertEqual(
            mailbox.route,
            (PairingProvisionMailbox.routeLabel + mailbox.authorization).sha256
        )
        let payload = try mailbox.open(Array(first.reversed()) + [first[0]])
        XCTAssertEqual(payload.archive, archive)
        XCTAssertEqual(payload.archiveHash, archive.sha256)
        XCTAssertEqual(payload.hostDeviceID, hostDeviceID)
    }

    func testPairingProvisionMailboxRejectsTamperingMissingChunksAndDirection()
        throws
    {
        let pairRoot = Data(repeating: 0x41, count: 32)
        let pairID = Data(repeating: 0x42, count: 16)
        let archive = Data(
            repeating: 0x43,
            count: ProtocolLimits.mailboxEnvelopeBytes + 1
        )
        let mailbox = try PairingProvisionMailbox(
            pairRoot: pairRoot,
            pairID: pairID
        )
        let envelopes = try mailbox.seal(
            archive: archive,
            hostDeviceID: Data(repeating: 0x44, count: 16)
        )

        var changedCiphertext = envelopes[0].ciphertext
        changedCiphertext[changedCiphertext.startIndex] ^= 1
        var tampered = envelopes
        tampered[0] = try StoredMailboxEnvelope(
            messageID: envelopes[0].messageID,
            ciphertext: changedCiphertext
        )
        XCTAssertThrowsError(try mailbox.open(tampered))
        XCTAssertThrowsError(try mailbox.open(Array(envelopes.dropLast())))
        XCTAssertThrowsError(
            try PairingProvisionMailbox(
                pairRoot: pairRoot,
                pairID: pairID,
                senderRole: .joiner
            )
        )
        let wrongRoot = try PairingProvisionMailbox(
            pairRoot: Data(repeating: 0x45, count: 32),
            pairID: pairID
        )
        XCTAssertThrowsError(try wrongRoot.open(envelopes))
    }

    func testPairingReadyMailboxRoundTripIsDeterministicAndBoundToTuple()
        throws
    {
        let pairRoot = Data(repeating: 0x51, count: 32)
        let pairID = Data(repeating: 0x52, count: 16)
        let hostDeviceID = Data(repeating: 0x53, count: 16)
        let joinerDeviceID = Data(repeating: 0x54, count: 16)
        let archiveHash = Data(repeating: 0x55, count: 32)
        let mailbox = try PairingReadyMailbox(
            pairRoot: pairRoot,
            pairID: pairID,
            hostDeviceID: hostDeviceID,
            archiveHash: archiveHash
        )

        let first = try mailbox.seal(joinerDeviceID: joinerDeviceID)
        let retry = try mailbox.seal(joinerDeviceID: joinerDeviceID)
        let record = try mailbox.open(first)

        XCTAssertEqual(first, retry)
        XCTAssertEqual(record.version, SyncProtocol.pairingVersion)
        XCTAssertEqual(record.pairID, pairID)
        XCTAssertEqual(record.hostDeviceID, hostDeviceID)
        XCTAssertEqual(record.joinerDeviceID, joinerDeviceID)
        XCTAssertEqual(record.archiveHash, archiveHash)
        XCTAssertEqual(
            mailbox.route,
            (PairingReadyMailbox.routeLabel + mailbox.authorization).sha256
        )

        let wrongTuple = try PairingReadyMailbox(
            pairRoot: pairRoot,
            pairID: pairID,
            hostDeviceID: hostDeviceID,
            archiveHash: Data(repeating: 0x56, count: 32)
        )
        XCTAssertThrowsError(try wrongTuple.open(first))

        var changedID = first.messageID
        changedID[changedID.startIndex] ^= 1
        XCTAssertThrowsError(
            try mailbox.open(
                StoredMailboxEnvelope(
                    messageID: changedID,
                    ciphertext: first.ciphertext
                )
            )
        )
    }

    func testPairingAbortMailboxRoundTripIsDeterministicAndDirectional()
        throws
    {
        let pairRoot = Data(repeating: 0x61, count: 32)
        let pairID = Data(repeating: 0x62, count: 16)
        let senderDeviceID = Data(repeating: 0x63, count: 16)
        let host = try PairingAbortMailbox(
            pairRoot: pairRoot,
            pairID: pairID,
            senderRole: .host
        )
        let joiner = try PairingAbortMailbox(
            pairRoot: pairRoot,
            pairID: pairID,
            senderRole: .joiner
        )

        let first = try host.seal(senderDeviceID: senderDeviceID)
        let retry = try host.seal(senderDeviceID: senderDeviceID)
        let record = try host.open(first)

        XCTAssertEqual(first, retry)
        XCTAssertEqual(record.version, SyncProtocol.pairingVersion)
        XCTAssertEqual(record.pairID, pairID)
        XCTAssertEqual(record.senderDeviceID, senderDeviceID)
        XCTAssertEqual(record.senderRole, .host)
        XCTAssertNotEqual(host.route, joiner.route)
        XCTAssertThrowsError(try joiner.open(first))

        var changedCiphertext = first.ciphertext
        changedCiphertext[changedCiphertext.startIndex] ^= 1
        XCTAssertThrowsError(
            try host.open(
                StoredMailboxEnvelope(
                    messageID: first.messageID,
                    ciphertext: changedCiphertext
                )
            )
        )
    }

    func testPairingControlV2UsesSharedLabelAndStageSeparatedRoutes()
        throws
    {
        let pairRoot = Data(repeating: 0x71, count: 32)
        let pairID = Data(repeating: 0x72, count: 16)
        let hostDeviceID = Data(repeating: 0x73, count: 16)
        let joinerDeviceID = Data(repeating: 0x74, count: 16)
        let archiveHash = Data(repeating: 0x75, count: 32)
        let provision = try PairingProvisionMailbox(
            pairRoot: pairRoot,
            pairID: pairID
        )
        let ready = try PairingReadyMailbox(
            pairRoot: pairRoot,
            pairID: pairID,
            hostDeviceID: hostDeviceID,
            archiveHash: archiveHash
        )
        let commit = try PairingCommitMailbox(
            pairRoot: pairRoot,
            record: PairingCommitRecord(
                pairID: pairID,
                hostDeviceID: hostDeviceID,
                joinerDeviceID: joinerDeviceID,
                archiveHash: archiveHash
            ),
            senderRole: .host
        )
        let abort = try PairingAbortMailbox(
            pairRoot: pairRoot,
            pairID: pairID,
            senderRole: .host
        )

        XCTAssertEqual(
            PairingProvisionMailbox.routeLabel,
            Data("com.gotdone.sync/pairing-control-route/v2".utf8)
        )
        XCTAssertEqual(
            PairingProvisionMailbox.routeLabel,
            PairingReadyMailbox.routeLabel
        )
        XCTAssertEqual(
            PairingProvisionMailbox.routeLabel,
            PairingCommitMailbox.routeLabel
        )
        XCTAssertEqual(
            PairingProvisionMailbox.routeLabel,
            PairingAbortMailbox.routeLabel
        )
        XCTAssertEqual(
            Set([
                provision.route,
                ready.route,
                commit.route,
                abort.route,
            ]).count,
            4
        )
    }

    func testStoredEnvelopeIsDeterministicAndDirectional() throws {
        let pairRoot = Data(0..<32)
        let pairID = Data(160..<176)
        let hostID = try ReplicaDeviceID(
            bytes: Data(repeating: 0x11, count: 16)
        )
        let joinerID = try ReplicaDeviceID(
            bytes: Data(repeating: 0x22, count: 16)
        )
        let operation = TaskOperation(
            originDeviceID: hostID,
            originSequence: 1,
            lamport: 1,
            taskID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            mutation: .create(title: "Offline", completed: false)
        )
        let host = try PairMailbox(
            credentials: credentials(
                pairRoot: pairRoot,
                pairID: pairID,
                role: .host,
                local: hostID,
                remote: joinerID
            )
        )
        let joiner = try PairMailbox(
            credentials: credentials(
                pairRoot: pairRoot,
                pairID: pairID,
                role: .joiner,
                local: joinerID,
                remote: hostID
            )
        )

        let first = try host.seal(operation)
        let retry = try host.seal(operation)

        XCTAssertEqual(first, retry)
        XCTAssertEqual(try joiner.open(first), operation)
        XCTAssertNotEqual(host.outbound.route, host.inbound.route)
        XCTAssertEqual(host.outbound.route, joiner.inbound.route)
        XCTAssertEqual(host.inbound.route, joiner.outbound.route)
        XCTAssertEqual(
            host.outbound.route,
            (MailboxKeyMaterial.routeLabel + host.outbound.authorization).sha256
        )
        XCTAssertThrowsError(try host.open(first))
    }

    func testStoredEnvelopeVersionOneVector() throws {
        let pairRoot = Data(0..<32)
        let pairID = Data(160..<176)
        let hostID = try ReplicaDeviceID(
            bytes: Data(repeating: 0x11, count: 16)
        )
        let joinerID = try ReplicaDeviceID(
            bytes: Data(repeating: 0x22, count: 16)
        )
        let operation = TaskOperation(
            originDeviceID: hostID,
            originSequence: 1,
            lamport: 1,
            taskID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            mutation: .create(title: "Offline", completed: false)
        )
        let host = try PairMailbox(
            credentials: credentials(
                pairRoot: pairRoot,
                pairID: pairID,
                role: .host,
                local: hostID,
                remote: joinerID
            )
        )
        let envelope = try host.seal(operation)

        XCTAssertEqual(
            host.outbound.route.hexString,
            "094c4fdd7654e4e688b4176223ec7a7edabc8b92167f78268d77b57eb4e1559e"
        )
        XCTAssertEqual(
            envelope.messageID.hexString,
            "cf5241d20e44a6afc74b4798a779646b1cf71e230d7b0204ac6cded1fe117757"
        )
        XCTAssertEqual(
            envelope.ciphertext.hexString,
            "8a45040a6c56da75cd2973c8df12a09cfc65b627c722befa87f90d6a3eb5d0c85b301fd72995abd8d36f3fe093ebb2462729fc6aada6610baf66def0cdc2753518feaba626e6fdf4a9e6e706729557b23f522d3915c0e659fc3c2ad487a8a21f76cc632d6b8125873459a375db856fc377bf55c392cf875cbfd249dcf84c237150191e5d51e5819e2c35accb5d9ce84c0aa65f51d40f43217952a50310ecdd4ea900af28085f3c7aab7c1f30a0934d02cc97099e911506422fbf4fe6c9ddb15747a56837dd4cb9f1417fea"
        )
    }

    func testStoredEnvelopeRejectsTamperingAndWrongPair() throws {
        let pairRoot = Data(repeating: 0x31, count: 32)
        let pairID = Data(repeating: 0x41, count: 16)
        let hostID = try ReplicaDeviceID(
            bytes: Data(repeating: 0x51, count: 16)
        )
        let joinerID = try ReplicaDeviceID(
            bytes: Data(repeating: 0x61, count: 16)
        )
        let operation = TaskOperation(
            originDeviceID: hostID,
            originSequence: 1,
            lamport: 1,
            taskID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            mutation: .create(title: "Private", completed: false)
        )
        let host = try PairMailbox(
            credentials: credentials(
                pairRoot: pairRoot,
                pairID: pairID,
                role: .host,
                local: hostID,
                remote: joinerID
            )
        )
        let joiner = try PairMailbox(
            credentials: credentials(
                pairRoot: pairRoot,
                pairID: pairID,
                role: .joiner,
                local: joinerID,
                remote: hostID
            )
        )
        let envelope = try host.seal(operation)

        var changedID = envelope.messageID
        changedID[changedID.startIndex] ^= 0x01
        let idTampered = try StoredMailboxEnvelope(
            messageID: changedID,
            ciphertext: envelope.ciphertext
        )
        XCTAssertThrowsError(try joiner.open(idTampered))

        var changedCiphertext = envelope.ciphertext
        changedCiphertext[changedCiphertext.startIndex] ^= 0x01
        let ciphertextTampered = try StoredMailboxEnvelope(
            messageID: envelope.messageID,
            ciphertext: changedCiphertext
        )
        XCTAssertThrowsError(try joiner.open(ciphertextTampered))

        let wrongPair = try PairMailbox(
            credentials: credentials(
                pairRoot: pairRoot,
                pairID: Data(repeating: 0x42, count: 16),
                role: .joiner,
                local: joinerID,
                remote: hostID
            )
        )
        XCTAssertThrowsError(try wrongPair.open(envelope))
    }

    func testHTTPMailboxRejectsStreamedOversizeResponse() async throws {
        MailboxURLProtocol.setResponseBody(
            Data(
                repeating: 0x7b,
                count: ProtocolLimits.mailboxRequestBytes + 1
            )
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MailboxURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
        }
        let transport = HTTPMailboxTransport(
            baseURL: TestEndpoints.mailboxURL,
            session: session,
            policy: .localDevelopment
        )

        do {
            _ = try await transport.fetch(
                route: Data(repeating: 0x01, count: 32),
                authorization: Data(repeating: 0x02, count: 32),
                after: 0,
                limit: 1
            )
            XCTFail("Expected the response-size limit.")
        } catch {
            XCTAssertEqual(
                error as? MailboxTransportError,
                .responseTooLarge
            )
        }
    }

    func testHTTPMailboxRetriesRateLimitedRequestsAfterRetryAfter() async throws {
        let rateLimited = Data(#"{"error":"rateLimited","version":1}"#.utf8)
        let page = Data(#"{"hasMore":false,"messages":[],"nextCursor":0,"version":1}"#.utf8)
        MailboxURLProtocol.setResponses([
            (rateLimited, 429, ["Retry-After": "0"]),
            (rateLimited, 429, ["Retry-After": "0"]),
            (page, 200, [:]),
        ])
        let (transport, session) = makeStubbedTransport()
        defer { session.invalidateAndCancel() }

        let fetched = try await transport.fetch(
            route: Data(repeating: 0x01, count: 32),
            authorization: Data(repeating: 0x02, count: 32),
            after: 0,
            limit: 1
        )

        XCTAssertEqual(fetched.messages, [])
        XCTAssertEqual(MailboxURLProtocol.requestCount, 3)
    }

    func testHTTPMailboxStopsRetryingRateLimitedRequestsAfterLimit() async throws {
        let rateLimited = Data(#"{"error":"rateLimited","version":1}"#.utf8)
        MailboxURLProtocol.setResponses(
            Array(repeating: (rateLimited, 429, ["Retry-After": "0"]), count: 5)
        )
        let (transport, session) = makeStubbedTransport()
        defer { session.invalidateAndCancel() }

        do {
            try await transport.forget(
                route: Data(repeating: 0x01, count: 32),
                authorization: Data(repeating: 0x02, count: 32)
            )
            XCTFail("Expected rate limit rejection")
        } catch {
            XCTAssertEqual(
                error as? MailboxTransportError,
                .rejected(status: 429, code: "rateLimited")
            )
        }
        XCTAssertEqual(
            MailboxURLProtocol.requestCount,
            HTTPMailboxTransport.maximumRateLimitRetries + 1
        )
    }

    func testHTTPMailboxDoesNotRetryCapacityOrLongRetryAfter() async throws {
        let cases: [([String: String], String)] = [
            ([:], "mailboxCapacity"),
            (["Retry-After": "3600"], "rateLimited"),
            (["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"], "rateLimited"),
        ]
        for (headers, code) in cases {
            MailboxURLProtocol.setResponses([
                (Data(#"{"error":"\#(code)","version":1}"#.utf8), 429, headers),
            ])
            let (transport, session) = makeStubbedTransport()
            defer { session.invalidateAndCancel() }
            do {
                try await transport.forget(
                    route: Data(repeating: 0x01, count: 32),
                    authorization: Data(repeating: 0x02, count: 32)
                )
                XCTFail("Expected rejection")
            } catch {
                XCTAssertEqual(
                    error as? MailboxTransportError,
                    .rejected(status: 429, code: code)
                )
            }
            XCTAssertEqual(MailboxURLProtocol.requestCount, 1)
        }
    }

    private func makeStubbedTransport() -> (HTTPMailboxTransport, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MailboxURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return (
            HTTPMailboxTransport(
                baseURL: TestEndpoints.mailboxURL,
                session: session,
                policy: .localDevelopment
            ),
            session
        )
    }

    private func credentials(
        pairRoot: Data,
        pairID: Data,
        role: DeviceRole,
        local: ReplicaDeviceID,
        remote: ReplicaDeviceID
    ) -> PairCredentials {
        PairCredentials(
            pairRoot: pairRoot,
            pairID: pairID,
            role: role,
            localDeviceID: local.bytes,
            remoteDeviceID: remote.bytes
        )
    }
}




private final class MailboxURLProtocol: URLProtocol, @unchecked Sendable {
    private static let responseLock = NSLock()
    nonisolated(unsafe) private static var responseBody = Data()
    nonisolated(unsafe) private static var responseStatus = 200
    nonisolated(unsafe) private static var queuedResponses: [(Data, Int, [String: String])] = []
    nonisolated(unsafe) private static var startedRequests = 0

    static func setResponseBody(_ data: Data, status: Int = 200) {
        responseLock.lock()
        responseBody = data
        responseStatus = status
        queuedResponses = []
        startedRequests = 0
        responseLock.unlock()
    }

    static func setResponses(_ responses: [(Data, Int, [String: String])]) {
        responseLock.lock()
        queuedResponses = responses
        startedRequests = 0
        responseLock.unlock()
    }

    static var requestCount: Int {
        responseLock.lock()
        defer { responseLock.unlock() }
        return startedRequests
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.responseLock.lock()
        var body = Self.responseBody
        var status = Self.responseStatus
        var headers = ["Content-Type": "application/json"]
        if !Self.queuedResponses.isEmpty {
            let queued = Self.queuedResponses.removeFirst()
            body = queued.0
            status = queued.1
            headers.merge(queued.2) { _, new in new }
        }
        Self.startedRequests += 1
        Self.responseLock.unlock()
        guard
            let url = request.url,
            let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )
        else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        let chunkSize = 16 * 1_024
        for start in stride(from: 0, to: body.count, by: chunkSize) {
            let end = min(start + chunkSize, body.count)
            client?.urlProtocol(
                self,
                didLoad: body.subdata(in: start..<end)
            )
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}


