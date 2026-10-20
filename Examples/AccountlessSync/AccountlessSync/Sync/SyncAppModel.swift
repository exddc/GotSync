import Combine
import Foundation
import GotSync
import UIKit

enum SyncNoticeKind: Equatable, Sendable {
    case saving
    case retrying
    case repair
}

struct SyncNotice: Equatable, Sendable {
    let kind: SyncNoticeKind
    let title: String
    let detail: String
}

@dynamicMemberLookup
@MainActor
final class SyncAppModel: ObservableObject {
    let engine: SyncEngine
    @Published private(set) var snapshot: SyncState
    private var observationTask: Task<Void, Never>?
    private var backgroundTaskIdentifier = UIBackgroundTaskIdentifier.invalid

    init(
        keychain: any SecretStore = KeychainStore(service: "org.gotsync.example.accountless"),
        baseDirectory: URL? = nil,
        relayURL: URL = DemoEndpoints.relayURL,
        mailboxURL: URL = DemoEndpoints.mailboxURL,
        backgroundMailboxScheduler: (any BackgroundMailboxScheduling)? = nil,
        pairingRetryDelayNanoseconds: UInt64 = 1_000_000_000
    ) {
        let directory = baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AccountlessSync", isDirectory: true)
        let configuration = try! SyncConfiguration(relayURL: relayURL, mailboxURL: mailboxURL, storageDirectory: directory, invitationURLScheme: DemoEndpoints.invitationURLScheme, endpointPolicy: DemoEndpoints.policy)
        engine = SyncEngine(configuration: configuration, secretStore: keychain, backgroundMailboxScheduler: backgroundMailboxScheduler ?? SystemBackgroundMailboxScheduler.shared, pairingRetryDelayNanoseconds: pairingRetryDelayNanoseconds)
        snapshot = engine.state
        let states = engine.states()
        observationTask = Task { [weak self] in
            for await state in states {
                guard let self else { return }
                let wasCelebrating = self.snapshot.showsLinkCompleteCelebration
                self.snapshot = state
                if state.showsLinkCompleteCelebration && !wasCelebrating {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            }
        }
    }

    deinit {
        observationTask?.cancel()
        let engine = engine
        Task { await engine.stop() }
    }

    subscript<Value>(dynamicMember keyPath: KeyPath<SyncEngine, Value>) -> Value {
        engine[keyPath: keyPath]
    }

    func createPrivateSync() { engine.createPrivateSync() }
    func joinPrivateSync(phrase: String) { engine.joinPrivateSync(phrase: phrase) }
    func joinPrivateSync(url: URL) { engine.joinPrivateSync(url: url) }
    func approveSafetyCode() { engine.approveSafetyCode() }
    func rejectSafetyCode() { engine.rejectSafetyCode() }
    func regenerateInvitation() { engine.regenerateInvitation() }
    func inviteToGroup() { engine.inviteToGroup() }
    func cancelPairing(preserveLink: Bool = false) { engine.cancelPairing(preserveLink: preserveLink) }
    func addTask(title: String) -> Bool { engine.addTask(title: title) }
    func clearLocalEditError() { engine.clearLocalEditError() }
    func toggleTask(_ task: ReplicatedTask) { engine.toggleTask(task) }
    func deleteTasks(at offsets: IndexSet) { engine.deleteTasks(at: offsets) }
    func deleteTasks(ids: [UUID]) { engine.deleteTasks(ids: ids) }
    func eraseLocalData() { endBackgroundFlush(); engine.eraseLocalData() }
    func unlinkAndKeepTasks() { endBackgroundFlush(); engine.unlinkAndKeepTasks() }
    func removeDevice(_ device: LinkedDevice) { engine.removeDevice(device) }
    func applicationDidBecomeActive() {
        endBackgroundFlush()
        engine.applicationDidBecomeActive()
    }
    func applicationDidEnterBackground() {
        endBackgroundFlush()
        backgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(withName: "Sync upload") { [weak self] in
            Task { @MainActor in
                await self?.engine.stopBackgroundWork()
                self?.endBackgroundFlush()
            }
        }
        engine.applicationDidEnterBackground()
        Task { [weak self] in
            await self?.engine.waitForBackgroundWork()
            self?.endBackgroundFlush()
        }
    }
    private func endBackgroundFlush() {
        guard backgroundTaskIdentifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskIdentifier)
        backgroundTaskIdentifier = .invalid
    }

    var syncNotice: SyncNotice? {
        if self.mailboxError == .unsupportedProtocolVersion {
            return SyncNotice(kind: .retrying, title: "Sync needs an update", detail: "Your tasks stay on this device. Update the app or contact the server operator to resume syncing.")
        }
        if self.phase == .failed || self.mailboxRequiresRepair {
            return SyncNotice(
                kind: .repair,
                title: "Link ended. Tasks kept",
                detail: "Your tasks stay on this phone. Create a link again when you are ready to link a replacement phone."
            )
        }
        if self.mailboxState == .unavailable {
            if self.mailboxCapacityReached {
                return SyncNotice(
                    kind: .retrying,
                    title: "Sync service is full",
                    detail: "Changes are saved on this iPhone. Upload retries automatically. Erase is not required."
                )
            }
            return SyncNotice(
                kind: .retrying,
                title: "Couldn’t reach the sync service. Retrying",
                detail: self.pendingMailboxOperationCount > 0
                    ? "Changes are saved on this phone. Upload retries automatically."
                    : "Tasks stay safe on this phone. Sync retries when the service is reachable."
            )
        }
        if self.pendingMailboxOperationCount > 0, self.showsSavingNotice {
            return SyncNotice(
                kind: .saving,
                title: "Saved on this iPhone",
                detail: "Upload to your linked phones continues in the background when possible. It appears there the next time those phones open Accountless Sync."
            )
        }
        return nil
    }

    var supportStatusSummary: SupportStatusSummary {
        SupportStatusSummary(
            linkOK: self.isPaired && self.phase != .failed && !self.mailboxRequiresRepair,
            lastUpdate: self.lastSyncedAt ?? self.lastMailboxReceivedAt ?? self.lastMailboxStoredAt,
            pendingSendCount: self.pendingMailboxOperationCount,
            otherPhoneMustBeOpenForLocalEdit: false,
            deliveryDetail: self.isPaired
                ? ProductSyncPolicy.deliverySummary
                : "This phone is not linked. Local edits stay here until you create or join a link."
        )
    }

    static func label(for device: LinkedDevice) -> String {
        if device.isCurrentDevice {
            return "This iPhone"
        }
        let short = device.deviceID.prefix(4).map {
            String(format: "%02x", $0)
        }.joined()
        return "iPhone · \(short)"
    }

    var manageSyncStatusLine: String {
        ProductSyncPolicy.linkedStatusSummary(memberCount: self.linkedMemberCount)
    }

    var userPairingPresentation: UserPairingPresentation {
        UserPairingPresentationBuilder.presentation(
            phase: self.phase,
            isHostApprovalPending: self.isHostApprovalPending,
            role: self.activePairingRole,
            errorMessage: self.errorMessage
        )
    }

    var statusTitle: String {
        if self.isPaired, self.phase != .failed {
            if self.pendingMailboxOperationCount > 0 {
                return "Saved on this iPhone"
            }
            if self.mailboxState == .unavailable {
                return "Sync will retry"
            }
            if self.showsLinkCompleteCelebration {
                return "Link is live"
            }
            if self.phase == .synced {
                return "Link is live"
            }
            if self.mailboxState == .syncing {
                return "Checking for changes"
            }
        }
        if self.isPaired, self.phase != .synced, self.phase != .failed {
            switch self.mailboxState {
            case .syncing:
                return "Checking for changes"
            case .available:
                return "Linked"
            case .unavailable:
                return "Sync will retry"
            case .idle:
                break
            }
        }
        return userPairingPresentation.title
    }

    var statusDetail: String {
        if self.isPaired, self.phase != .failed {
            if self.pendingMailboxOperationCount > 0 {
                return self.pendingMailboxOperationCount == 1
                    ? "One change is waiting to reach your other phone. It appears there the next time that phone opens Accountless Sync."
                    : "\(self.pendingMailboxOperationCount) changes are waiting to reach your other phone. They appear there the next time that phone opens Accountless Sync."
            }
            if self.mailboxState == .unavailable {
                return "Tasks stay safe here. Sync retries automatically."
            }
            if self.showsLinkCompleteCelebration {
                return ProductSyncPolicy.deliverySummary
            }
            if self.phase == .synced {
                return ProductSyncPolicy.deliverySummary
            }
        }
        if self.isPaired, self.phase != .synced, self.phase != .failed {
            switch self.mailboxState {
            case .syncing:
                return "Looking for updates saved while this iPhone was away."
            case .available:
                return ProductSyncPolicy.deliverySummary
            case .unavailable, .idle:
                break
            }
        }
        if self.phase == .offline {
            return "Tasks stay safe on this phone. Upload continues when the app can reach the sync service."
        }
        return userPairingPresentation.detail
    }
}
