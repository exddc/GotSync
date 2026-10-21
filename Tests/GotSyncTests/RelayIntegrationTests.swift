import Foundation
import XCTest
@testable import GotSync

final class RelayIntegrationTests: XCTestCase {
    @MainActor
    func testPairAndSyncThroughRealRelayOverMLS() async throws {
        guard ProcessInfo.processInfo.environment["GOTSYNC_INTEGRATION"] == "1" else {
            if ProcessInfo.processInfo.environment["GOTSYNC_REQUIRE_INTEGRATION"] == "1" {
                XCTFail("The required relay integration environment is missing.")
                return
            }
            throw XCTSkip("Run scripts/test-integration.sh to start the real relay.")
        }
        let relayURL = try XCTUnwrap(URL(string: ProcessInfo.processInfo.environment["GOTSYNC_RELAY_URL"] ?? ""))
        let mailboxURL = try XCTUnwrap(URL(string: ProcessInfo.processInfo.environment["GOTSYNC_MAILBOX_URL"] ?? ""))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hostStore = MemorySecretStore()
        let joinerStore = MemorySecretStore()
        let thirdStore = MemorySecretStore()
        let fourthStore = MemorySecretStore()
        func engine(_ name: String, store: MemorySecretStore) throws -> SyncEngine {
            let configuration = try SyncConfiguration(relayURL: relayURL, mailboxURL: mailboxURL, storageDirectory: directory.appendingPathComponent(name), invitationURLScheme: "gotsync-tests", endpointPolicy: .localDevelopment)
            return SyncEngine(configuration: configuration, secretStore: store, pairingRetryDelayNanoseconds: 100_000_000)
        }
        let host = try engine("host", store: hostStore)
        var joiner = try engine("joiner", store: joinerStore)
        let third = try engine("third", store: thirdStore)
        let fourth = try engine("fourth", store: fourthStore)
        do {
            XCTAssertTrue(host.addTask(title: "Shared before pairing"))
            host.createPrivateSync()
            try await wait("founding invite", engines: [host, joiner]) { host.invitationURL != nil }
            joiner.joinPrivateSync(url: try XCTUnwrap(host.invitationURL))
            try await wait("safety check", engines: [host, joiner]) { host.isHostApprovalPending && joiner.safetyCode != nil }
            XCTAssertEqual(host.safetyCode, joiner.safetyCode)
            host.approveSafetyCode()
            try await wait("founding pair", engines: [host, joiner]) { host.isPaired && joiner.isPaired }
            XCTAssertEqual(host.linkedMemberCount, 2)
            try await wait("provisioned task", engines: [host, joiner]) { joiner.tasks.count == 1 }
            XCTAssertTrue(joiner.addTask(title: "Live peer edit"))
            try await wait("live convergence", engines: [host, joiner]) { host.tasks.count == 2 && host.phase == .synced && joiner.phase == .synced }

            await joiner.stop()
            XCTAssertTrue(host.addTask(title: "Offline recipient edit"))
            try await wait("durable upload", engines: [host]) { host.pendingMailboxOperationCount == 0 }
            host.applicationDidEnterBackground()
            await host.waitForBackgroundWork()
            joiner = try engine("joiner", store: joinerStore)
            XCTAssertTrue(joiner.isPaired)
            try await wait("catch up after restart", engines: [host, joiner]) { joiner.tasks.count == 3 }

            XCTAssertNotNil(joiner.lastMailboxReceivedAt)
            host.applicationDidBecomeActive()
            host.inviteToGroup()
            try await wait("third-device invite", engines: [host, third]) { host.invitationURL != nil }
            third.joinPrivateSync(url: try XCTUnwrap(host.invitationURL))
            try await wait("third-device safety check", engines: [host, third]) { host.isHostApprovalPending && third.safetyCode != nil }
            XCTAssertEqual(host.safetyCode, third.safetyCode)
            host.approveSafetyCode()
            try await wait("multi-device membership", engines: [host, joiner, third]) { host.linkedMemberCount == 3 && joiner.linkedMemberCount == 3 && third.linkedMemberCount == 3 && third.isPaired }
            try await wait("third-device history", engines: [host, third]) { third.tasks.count == 3 }
            XCTAssertTrue(third.addTask(title: "Third device edit"))
            try await wait("multi-device convergence", engines: [host, joiner, third]) { host.tasks.count == 4 && joiner.tasks.count == 4 && third.tasks.count == 4 }
            XCTAssertEqual(host.tasks.map(\.titleValue), joiner.tasks.map(\.titleValue))
            XCTAssertEqual(host.tasks.map(\.titleValue), third.tasks.map(\.titleValue))

            let thirdSession = try XCTUnwrap(third.mlsSessionForTesting)
            let group = try await thirdSession.group()
            let thirdAuthorization = try await thirdSession.client.transportAuthorization()
            let removedDevice = try XCTUnwrap(host.linkedDevices.first { $0.deviceID == third.localDeviceID })
            XCTAssertTrue(host.removeDevice(removedDevice))
            try await wait("third device removed", engines: [host, joiner, third]) {
                host.linkedMemberCount == 2 && joiner.linkedMemberCount == 2 && !third.isPaired
            }
            XCTAssertEqual(third.errorMessage, SyncError.removedFromGroup.errorDescription)
            XCTAssertTrue(joiner.addTask(title: "After removal"))
            try await wait("remaining devices converge", engines: [host, joiner]) { host.tasks.count == 5 && joiner.pendingMailboxOperationCount == 0 }
            try await Task.sleep(for: .seconds(1))
            XCTAssertEqual(third.tasks.count, 4)
            let relay = HTTPMLSRelayTransport(
                baseURL: try SyncEndpointConfiguration(relayURL: relayURL, mailboxURL: mailboxURL, policy: .localDevelopment).mlsURL,
                policy: .localDevelopment
            )
            do {
                _ = try await relay.fetch(group: try XCTUnwrap(group), after: 0, limit: 8, authorization: thirdAuthorization)
                XCTFail("The relay served a removed device")
            } catch MLSRelayError.unauthorized {}
            host.inviteToGroup()
            try await wait("teardown invite", engines: [host, fourth]) { host.invitationURL != nil }
            fourth.joinPrivateSync(url: try XCTUnwrap(host.invitationURL))
            try await wait("host approval before teardown", engines: [host, fourth]) { host.isHostApprovalPending && fourth.safetyCode != nil }
            let stopped = expectation(description: "stop returns during host approval")
            var stopReturned = false
            Task { @MainActor in
                await host.stop()
                stopReturned = true
                stopped.fulfill()
            }
            await fulfillment(of: [stopped], timeout: 1)
            guard stopReturned else {
                await joiner.stop()
                await third.stop()
                await fourth.stop()
                return
            }
        } catch {
            await host.stop()
            await joiner.stop()
            await third.stop()
            await fourth.stop()
            throw error
        }
        await host.stop()
        await joiner.stop()
        await third.stop()
        await fourth.stop()
    }

    @MainActor
    private func wait(_ stage: String, engines: [SyncEngine], until predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                let details = engines.map { "\($0.phase): \($0.errorMessage ?? $0.mailboxErrorMessage ?? "no error")" }.joined(separator: "; ")
                XCTFail("Timed out at \(stage): \(details)")
                throw IntegrationError.timeout
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

private enum IntegrationError: Error {
    case timeout
}
