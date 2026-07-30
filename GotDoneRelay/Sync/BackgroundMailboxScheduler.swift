import BackgroundTasks
import Foundation
import UIKit

/// Schedules deferred mailbox upload when the app leaves the foreground with
/// pending outbound operations. Unit tests inject a no-op or recording stub.
@MainActor
protocol BackgroundMailboxScheduling: AnyObject {
    func register(
        handler: @escaping @MainActor () async -> Void
    )
    func scheduleFlushIfNeeded(pendingOperationCount: Int)
    func cancelFlush()
}

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

/// Recording scheduler for unit tests.
@MainActor
final class RecordingBackgroundMailboxScheduler: BackgroundMailboxScheduling {
    private(set) var scheduleCalls: [Int] = []
    private(set) var cancelCount = 0
    private(set) var isRegistered = false
    var handler: (@MainActor () async -> Void)?

    func register(handler: @escaping @MainActor () async -> Void) {
        self.handler = handler
        isRegistered = true
    }

    func scheduleFlushIfNeeded(pendingOperationCount: Int) {
        scheduleCalls.append(pendingOperationCount)
        if pendingOperationCount <= 0 {
            cancelCount += 1
        }
    }

    func cancelFlush() {
        cancelCount += 1
    }

    func fireHandlerForTesting() async {
        await handler?()
    }
}
