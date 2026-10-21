import Foundation
import XCTest
@testable import GotSync

final class ProtocolCompatibilityTests: XCTestCase {
    func testInvitationSecretsAreFreshAndRoundTripThroughPhrase() throws {
        let group = Data(repeating: 0x01, count: 32)
        let fingerprint = Data(repeating: 0x02, count: 32)
        let first = try Invitation.generate(groupID: group, inviterFingerprint: fingerprint)
        let second = try Invitation.generate(groupID: group, inviterFingerprint: fingerprint)
        XCTAssertEqual(first.secret.count, 16)
        XCTAssertNotEqual(first.secret, second.secret)
        XCTAssertEqual(try Invitation.from(phrase: first.phrase).secret, first.secret)
        XCTAssertEqual(SyncTiming.invitationTimeToLive, 15 * 60)
    }

    func testConfigurationDefaultsToProductionInEveryBuild() {
        XCTAssertThrowsError(try SyncConfiguration(relayURL: TestEndpoints.relayURL, mailboxURL: TestEndpoints.mailboxURL, storageDirectory: FileManager.default.temporaryDirectory, invitationURLScheme: "gotsync-tests"))
        XCTAssertNoThrow(try SyncConfiguration(relayURL: TestEndpoints.relayURL, mailboxURL: TestEndpoints.mailboxURL, storageDirectory: FileManager.default.temporaryDirectory, invitationURLScheme: "gotsync-tests", endpointPolicy: .localDevelopment))
    }

    func testInvitationSchemeBelongsToConsumer() throws {
        let invitation = try Invitation(
            secret: Data(0..<16),
            groupID: Data(repeating: 0x01, count: 32),
            inviterFingerprint: Data(repeating: 0x02, count: 32)
        )
        let url = try invitation.url(scheme: "first-consumer")
        XCTAssertEqual(url.scheme, "first-consumer")
        XCTAssertEqual(try Invitation.from(url: url, scheme: "first-consumer"), invitation)
        XCTAssertThrowsError(try Invitation.from(url: url, scheme: "second-consumer"))
        for scheme in ["", "bad scheme", "https", "1invalid", "consumer\n", "consumer\r\n"] {
            XCTAssertThrowsError(try invitation.url(scheme: scheme))
        }
    }

    @MainActor
    func testStopFinishesStateStream() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = SyncEngine(baseDirectory: directory)
        var states = engine.states().makeAsyncIterator()
        _ = await states.next()
        await engine.stop()
        let end = await states.next()
        XCTAssertNil(end)
    }

    @MainActor
    func testStateStreamYieldsCurrentAndUpdatedReplica() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = SyncEngine(baseDirectory: directory)
        var states = engine.states().makeAsyncIterator()
        let first = await states.next()
        XCTAssertEqual(first?.phase, .unpaired)
        XCTAssertEqual(first?.tasks.count, 0)
        XCTAssertTrue(engine.addTask(title: "Local stream update"))
        let next = await states.next()
        XCTAssertEqual(next?.tasks.first?.titleValue, "Local stream update")
        XCTAssertEqual(next?.pendingMailboxOperationCount, 1)
        await engine.stop()
    }
}
