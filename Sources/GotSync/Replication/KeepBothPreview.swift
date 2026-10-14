import Foundation

/// Outcome model for combining two task lists during join (D11).
public struct KeepBothPreview: Equatable, Sendable {
    /// Tasks present on both lists with identical title and completion.
    public let reusedCount: Int
    /// Tasks only on this iPhone (will be added once).
    public let localOnlyCount: Int
    /// Same task identity differs — may appear twice after combine.
    public let conflictCount: Int
    /// Tasks only on the main iPhone’s imported list.
    public let sharedOnlyCount: Int

    public var isAdditiveOnly: Bool {
        conflictCount == 0
    }

    public var totalVisibleAfterCombine: Int {
        reusedCount + localOnlyCount + conflictCount * 2 + sharedOnlyCount
    }

    public var confirmationSummary: String {
        var parts: [String] = []
        if reusedCount > 0 {
            parts.append(
                reusedCount == 1
                    ? "1 shared task stays as-is"
                    : "\(reusedCount) shared tasks stay as-is"
            )
        }
        if localOnlyCount > 0 {
            parts.append(
                localOnlyCount == 1
                    ? "1 local-only task is added"
                    : "\(localOnlyCount) local-only tasks are added"
            )
        }
        if sharedOnlyCount > 0 {
            parts.append(
                sharedOnlyCount == 1
                    ? "1 task from the other iPhone is added"
                    : "\(sharedOnlyCount) tasks from the other iPhone are added"
            )
        }
        if conflictCount > 0 {
            parts.append(
                conflictCount == 1
                    ? "1 conflicting task may appear twice"
                    : "\(conflictCount) conflicting tasks may appear twice"
            )
        }
        if parts.isEmpty {
            return "Both lists are empty. Combining keeps this iPhone unchanged."
        }
        return parts.joined(separator: ". ") + "."
    }
}

extension TaskReplica {
    /// Pure preflight for Keep Both — does not mutate either replica.
    static func keepBothPreview(
        staged: TaskReplica,
        local: TaskReplica
    ) throws -> KeepBothPreview {
        guard staged.deviceID == local.deviceID else {
            throw ReplicaError.archiveDeviceMismatch(
                expected: staged.deviceID,
                actual: local.deviceID
            )
        }

        var reused = 0
        var localOnly = 0
        var conflicts = 0
        var matchedStagedIDs = Set<UUID>()

        for task in local.tasks where !task.isDeleted {
            guard
                let title = task.titleValue,
                let completed = task.isCompleted
            else {
                throw ReplicaError.corruptArchive(
                    "A visible task is missing materialized fields."
                )
            }
            if let existing = staged.task(id: task.id), !existing.isDeleted {
                if
                    existing.titleValue == title,
                    existing.isCompleted == completed
                {
                    reused += 1
                    matchedStagedIDs.insert(task.id)
                } else {
                    conflicts += 1
                    matchedStagedIDs.insert(task.id)
                }
            } else {
                localOnly += 1
            }
        }

        let sharedOnly = staged.tasks.filter {
            !$0.isDeleted && !matchedStagedIDs.contains($0.id)
        }.count

        return KeepBothPreview(
            reusedCount: reused,
            localOnlyCount: localOnly,
            conflictCount: conflicts,
            sharedOnlyCount: sharedOnly
        )
    }
}
