import Foundation
import XCTest
@testable import GotSync

final class ProtocolCompatibilityTests: XCTestCase {
    func testWireVersionIsRejectedBeforeUnknownKind() throws {
        for body in [#"{"version":2,"kind":"future"}"#, #"{"version":0,"kind":"hello"}"#, #"{"kind":"hello"}"#, #"{"version":true,"kind":"hello"}"#] {
            XCTAssertThrowsError(try WireCodec.decode(SyncWireMessage.self, from: Data(body.utf8))) { error in
                XCTAssertEqual(error as? WireMessageError, .invalidVersion)
            }
        }
    }

    func testConfigurationDefaultsToProductionInEveryBuild() {
        XCTAssertThrowsError(try SyncConfiguration(relayURL: TestEndpoints.relayURL, mailboxURL: TestEndpoints.mailboxURL, storageDirectory: FileManager.default.temporaryDirectory, invitationURLScheme: "gotsync-tests"))
        XCTAssertNoThrow(try SyncConfiguration(relayURL: TestEndpoints.relayURL, mailboxURL: TestEndpoints.mailboxURL, storageDirectory: FileManager.default.temporaryDirectory, invitationURLScheme: "gotsync-tests", endpointPolicy: .localDevelopment))
    }

    func testInvitationSchemeBelongsToConsumer() throws {
        let invitation = try Invitation(secret: Data(0..<16))
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
