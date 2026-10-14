import GotSync
import BackgroundTasks
import Foundation
import UIKit

@MainActor
final class SystemBackgroundMailboxScheduler: BackgroundMailboxScheduling {
    static let shared = SystemBackgroundMailboxScheduler()

    private var handler: (@MainActor () async -> Void)?
    private var isRegistered = false

    func register(handler: @escaping @MainActor () async -> Void) {
        self.handler = handler
        guard !isRegistered else {
            return
        }
        isRegistered = true
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: ProductSyncPolicy.backgroundMailboxTaskIdentifier,
            using: nil
        ) { task in
            guard let processing = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                let work = self.handler
                processing.expirationHandler = {
                    processing.setTaskCompleted(success: false)
                }
                await work?()
                processing.setTaskCompleted(success: true)
            }
        }
    }

    func scheduleFlushIfNeeded(pendingOperationCount: Int) {
        guard pendingOperationCount > 0 else {
            cancelFlush()
            return
        }
        let request = BGProcessingTaskRequest(
            identifier: ProductSyncPolicy.backgroundMailboxTaskIdentifier
        )
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        // Earliest start: let the OS pick a window soon after backgrounding.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Scheduling is best-effort; UIBackgroundTask still covers the
            // immediate background window.
        }
    }

    func cancelFlush() {
        BGTaskScheduler.shared.cancel(
            taskRequestWithIdentifier: ProductSyncPolicy.backgroundMailboxTaskIdentifier
        )
    }
}
