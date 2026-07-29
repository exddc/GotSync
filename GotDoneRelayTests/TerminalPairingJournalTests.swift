import Foundation
import XCTest
@testable import GotDoneRelay

final class TerminalPairingJournalTests: XCTestCase {
    func testReceiptRoundTripsWithoutRetainingPairRoot() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        let receipt = try makeReceiptAction(
            seed: 0x11,
            localDeviceID: fixture.localDeviceID
        )

        try fixture.store.upsertTerminalPairingAction(receipt.action)

        XCTAssertEqual(
            try fixture.store.terminalPairingActions(),
            [receipt.action]
        )
        XCTAssertEqual(
            try receipt.action.envelope,
            receipt.envelope
        )
        let encoded = try XCTUnwrap(
            fixture.keychain.read(
                account: CredentialStore.terminalPairingActionsAccount
            )
        )
        let encodedText = try XCTUnwrap(
            String(data: encoded, encoding: .utf8)
        )
        XCTAssertFalse(
            encodedText.contains(
                receipt.pending.pairRoot.base64EncodedString()
            )
        )
        XCTAssertFalse(
            encodedText.contains(
                receipt.pending.archiveHash.base64EncodedString()
            )
        )
    }

    func testAbortProofAllowsOnlyPreCommitCancellationStates() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        let joiner = try makeAbortAction(
            seed: 0x21,
            role: .joiner,
            state: .waitingForProvision,
            localDeviceID: fixture.localDeviceID
        )
        let host = try makeAbortAction(
            seed: 0x31,
            role: .host,
            state: .provisionMayHaveBeenStored,
            localDeviceID: fixture.localDeviceID
        )

        XCTAssertEqual(joiner.action.kind, .abort)
        XCTAssertEqual(host.action.kind, .abort)
        XCTAssertThrowsError(
            try makeAbortAction(
                seed: 0x41,
                role: .joiner,
                state: .readyMayHaveBeenStored,
                localDeviceID: fixture.localDeviceID
            )
        ) {
            XCTAssertEqual(
                $0 as? TerminalPairingJournalError,
                .invalidAction
            )
        }
        XCTAssertThrowsError(
            try makeAbortAction(
                seed: 0x51,
                role: .host,
                state: .commitMarkerMayHaveBeenStored,
                localDeviceID: fixture.localDeviceID
            )
        ) {
            XCTAssertEqual(
                $0 as? TerminalPairingJournalError,
                .invalidAction
            )
        }
    }

    func testJournalUpsertIsIdempotentAndRejectsConflicts() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        let abort = try makeAbortAction(
            seed: 0x61,
            role: .joiner,
            state: .waitingForProvision,
            localDeviceID: fixture.localDeviceID
        )
        var journal = try TerminalPairingActionJournal()

        try journal.upsert(abort.action)
        try journal.upsert(abort.action)

        XCTAssertEqual(journal.actions, [abort.action])
        var ciphertext = abort.envelope.ciphertext
        ciphertext[ciphertext.startIndex] ^= 0x01
        let conflictingEnvelope = try StoredMailboxEnvelope(
            messageID: abort.envelope.messageID,
            ciphertext: ciphertext
        )
        let conflicting = try TerminalPairingAction(
            kind: .abort,
            proof: abort.pending,
            route: abort.action.route,
            authorization: abort.action.authorization,
            envelope: conflictingEnvelope
        )
        XCTAssertThrowsError(try journal.upsert(conflicting)) {
            XCTAssertEqual(
                $0 as? TerminalPairingJournalError,
                .conflictingAction
            )
        }
        XCTAssertEqual(journal.actions, [abort.action])
    }

    func testJournalRefusesSilentEvictionAtCapacity() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        var journal = try TerminalPairingActionJournal()
        var first: TerminalPairingAction?
        for index in 0..<TerminalPairingActionJournal.maximumActionCount {
            let abort = try makeAbortAction(
                seed: UInt8(index + 1),
                role: .joiner,
                state: .waitingForProvision,
                localDeviceID: fixture.localDeviceID
            )
            first = first ?? abort.action
            try journal.upsert(abort.action)
        }

        XCTAssertEqual(
            journal.actions.count,
            TerminalPairingActionJournal.maximumActionCount
        )
        try journal.upsert(try XCTUnwrap(first))
        let overflow = try makeAbortAction(
            seed: 0x7F,
            role: .joiner,
            state: .waitingForProvision,
            localDeviceID: fixture.localDeviceID
        )
        XCTAssertThrowsError(try journal.upsert(overflow.action)) {
            XCTAssertEqual(
                $0 as? TerminalPairingJournalError,
                .actionLimitExceeded(
                    TerminalPairingActionJournal.maximumActionCount
                )
            )
        }
        XCTAssertEqual(
            journal.actions.count,
            TerminalPairingActionJournal.maximumActionCount
        )
    }

    func testCurrentPairClearPreservesJournalAndFullEraseClearsIt() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        let first = try makeAbortAction(
            seed: 0x81,
            role: .joiner,
            state: .waitingForProvision,
            localDeviceID: fixture.localDeviceID
        )
        let second = try makeReceiptAction(
            seed: 0x91,
            localDeviceID: fixture.localDeviceID
        )
        try fixture.store.saveActive(
            credentials(for: second.pending)
        )
        try fixture.store.savePending(second.pending)
        try fixture.store.saveMailboxCheckpoint(
            MailboxCheckpoint(
                pairID: second.pending.pairID,
                uploadedLocalSequence: 3
            )
        )
        try fixture.store.upsertTerminalPairingAction(first.action)
        try fixture.store.upsertTerminalPairingAction(second.action)

        try fixture.store.clearCurrentPair()

        XCTAssertNil(try fixture.store.active())
        XCTAssertNil(try fixture.store.pending())
        XCTAssertNil(try fixture.store.mailboxCheckpoint())
        XCTAssertEqual(
            try fixture.store.terminalPairingActions(),
            [first.action, second.action].sorted(by: actionOrder)
        )

        try fixture.store.removeTerminalPairingAction(first.action.key)

        XCTAssertEqual(
            try fixture.store.terminalPairingActions(),
            [second.action]
        )
        try fixture.store.clearAllPairingData()
        XCTAssertTrue(try fixture.store.terminalPairingActions().isEmpty)
    }

    func testAppendThenClearRequiresMatchingPendingPair() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        let first = try makeAbortAction(
            seed: 0xA1,
            role: .joiner,
            state: .waitingForProvision,
            localDeviceID: fixture.localDeviceID
        )
        let second = try makeAbortAction(
            seed: 0xA2,
            role: .joiner,
            state: .waitingForProvision,
            localDeviceID: fixture.localDeviceID
        )
        try fixture.store.savePending(first.pending)

        XCTAssertThrowsError(
            try fixture.store
                .upsertTerminalPairingActionThenClearPending(second.action)
        ) {
            XCTAssertEqual(
                $0 as? TerminalPairingJournalError,
                .pendingActionMismatch
            )
        }
        XCTAssertEqual(try fixture.store.pending(), first.pending)
        XCTAssertTrue(try fixture.store.terminalPairingActions().isEmpty)

        try fixture.store
            .upsertTerminalPairingActionThenClearPending(first.action)

        XCTAssertNil(try fixture.store.pending())
        XCTAssertEqual(
            try fixture.store.terminalPairingActions(),
            [first.action]
        )
    }

    func testLegacyJournalKeysAndMissingVersionsDecode() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        let abort = try makeAbortAction(
            seed: 0xB1,
            role: .joiner,
            state: .waitingForProvision,
            localDeviceID: fixture.localDeviceID
        )
        let legacy = LegacyTerminalPairingJournal(
            records: [
                LegacyTerminalPairingAction(action: abort.action)
            ]
        )
        try fixture.keychain.write(
            CanonicalJSON.encoder.encode(legacy),
            account: CredentialStore.terminalPairingActionsAccount
        )

        XCTAssertEqual(
            try fixture.store.terminalPairingActions(),
            [abort.action]
        )
    }

    func testStrictDecodeRejectsDuplicateAndForeignActions() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        let abort = try makeAbortAction(
            seed: 0xC1,
            role: .joiner,
            state: .waitingForProvision,
            localDeviceID: fixture.localDeviceID
        )
        let duplicate = LegacyTerminalPairingJournal(
            records: [
                LegacyTerminalPairingAction(action: abort.action),
                LegacyTerminalPairingAction(action: abort.action),
            ]
        )
        try fixture.keychain.write(
            CanonicalJSON.encoder.encode(duplicate),
            account: CredentialStore.terminalPairingActionsAccount
        )

        XCTAssertThrowsError(
            try fixture.store.terminalPairingActions()
        ) {
            XCTAssertEqual(
                $0 as? TerminalPairingJournalError,
                .duplicateAction
            )
        }
        try fixture.store.clearTerminalPairingActions()
        let foreignFixture = try makeStoreFixture()
        defer { foreignFixture.cleanup() }
        try fixture.store.upsertTerminalPairingAction(abort.action)
        let encoded = try XCTUnwrap(
            fixture.keychain.read(
                account: CredentialStore.terminalPairingActionsAccount
            )
        )
        try foreignFixture.keychain.write(
            encoded,
            account: CredentialStore.terminalPairingActionsAccount
        )

        XCTAssertThrowsError(
            try foreignFixture.store.terminalPairingActions()
        ) {
            XCTAssertEqual(
                $0 as? TerminalPairingJournalError,
                .localIdentityMismatch
            )
        }
    }

    func testNewConflictStateCodableRoundTrip() throws {
        let state = PairingFinalizationState
            .provisionStagedAwaitingMergeApproval
        let encoded = try CanonicalJSON.encoder.encode(state)

        XCTAssertEqual(
            try CanonicalJSON.decoder.decode(
                PairingFinalizationState.self,
                from: encoded
            ),
            state
        )
    }

    private func makeStoreFixture() throws -> StoreFixture {
        let keychain = KeychainStore(
            service: "com.gotdone.relay.tests.\(UUID().uuidString)"
        )
        let identity = try InstallIdentity.loadOrCreate(store: keychain)
        return StoreFixture(
            keychain: keychain,
            store: CredentialStore(keychain: keychain),
            localDeviceID: identity.deviceID
        )
    }

    private func makeAbortAction(
        seed: UInt8,
        role: DeviceRole,
        state: PairingFinalizationState,
        localDeviceID: Data
    ) throws -> ActionFixture {
        let pairRoot = Data(repeating: seed, count: 32)
        let pairID = Data(repeating: seed &+ 1, count: 16)
        let pending = PendingPair(
            version: SyncProtocol.version,
            pairRoot: pairRoot,
            pairID: pairID,
            role: role,
            localDeviceID: localDeviceID,
            remoteDeviceID: state == .readyMayHaveBeenStored
                || state == .commitMarkerMayHaveBeenStored
                ? Data(repeating: seed &+ 2, count: 16)
                : nil,
            archiveHash: state == .provisionMayHaveBeenStored
                || state == .readyMayHaveBeenStored
                || state == .commitMarkerMayHaveBeenStored
                ? Data(repeating: seed &+ 3, count: 32)
                : Data(),
            expiresAt: .distantPast,
            finalizationState: state
        )
        let mailbox = try PairingAbortMailbox(
            pairRoot: pairRoot,
            pairID: pairID,
            senderRole: role
        )
        let envelope = try mailbox.seal(
            senderDeviceID: localDeviceID
        )
        return ActionFixture(
            pending: pending,
            envelope: envelope,
            action: try TerminalPairingAction(
                kind: .abort,
                proof: pending,
                route: mailbox.route,
                authorization: mailbox.authorization,
                envelope: envelope
            )
        )
    }

    private func makeReceiptAction(
        seed: UInt8,
        localDeviceID: Data
    ) throws -> ActionFixture {
        let pairRoot = Data(repeating: seed, count: 32)
        let pairID = Data(repeating: seed &+ 1, count: 16)
        let remoteDeviceID = Data(repeating: seed &+ 2, count: 16)
        let archiveHash = Data(repeating: seed &+ 3, count: 32)
        let pending = PendingPair(
            version: SyncProtocol.version,
            pairRoot: pairRoot,
            pairID: pairID,
            role: .joiner,
            localDeviceID: localDeviceID,
            remoteDeviceID: remoteDeviceID,
            archiveHash: archiveHash,
            expiresAt: .distantPast,
            finalizationState: .readyMayHaveBeenStored
        )
        let record = try PairingCommitRecord(
            pairID: pairID,
            hostDeviceID: remoteDeviceID,
            joinerDeviceID: localDeviceID,
            archiveHash: archiveHash
        )
        let mailbox = try PairingCommitMailbox(
            pairRoot: pairRoot,
            record: record,
            senderRole: .joiner
        )
        let envelope = try mailbox.seal()
        return ActionFixture(
            pending: pending,
            envelope: envelope,
            action: try TerminalPairingAction(
                kind: .receipt,
                proof: pending,
                route: mailbox.route,
                authorization: mailbox.authorization,
                envelope: envelope
            )
        )
    }

    private func credentials(
        for pending: PendingPair
    ) throws -> PairCredentials {
        PairCredentials(
            pairRoot: pending.pairRoot,
            pairID: pending.pairID,
            role: pending.role,
            localDeviceID: pending.localDeviceID,
            remoteDeviceID: try XCTUnwrap(pending.remoteDeviceID)
        )
    }

    private func actionOrder(
        _ lhs: TerminalPairingAction,
        _ rhs: TerminalPairingAction
    ) -> Bool {
        if lhs.pairID != rhs.pairID {
            return lhs.pairID.lexicographicallyPrecedes(rhs.pairID)
        }
        return lhs.kind.rawValue < rhs.kind.rawValue
    }
}

private struct StoreFixture {
    let keychain: KeychainStore
    let store: CredentialStore
    let localDeviceID: Data

    func cleanup() {
        try? store.clearAllPairingData()
        try? keychain.delete(account: InstallIdentity.account)
    }
}

private struct ActionFixture {
    let pending: PendingPair
    let envelope: StoredMailboxEnvelope
    let action: TerminalPairingAction
}

private struct LegacyTerminalPairingAction: Codable {
    let pairID: Data
    let kind: TerminalPairingActionKind
    let role: DeviceRole
    let localDeviceID: Data
    let remoteDeviceID: Data?
    let route: Data
    let authorization: Data
    let messageID: Data
    let ciphertext: Data

    init(action: TerminalPairingAction) {
        pairID = action.pairID
        kind = action.kind
        role = action.role
        localDeviceID = action.localDeviceID
        remoteDeviceID = action.remoteDeviceID
        route = action.route
        authorization = action.authorization
        messageID = action.messageID
        ciphertext = action.ciphertext
    }
}

private struct LegacyTerminalPairingJournal: Codable {
    let records: [LegacyTerminalPairingAction]
}
