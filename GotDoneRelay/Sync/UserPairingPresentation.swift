import Foundation

/// One-screen support answer for “is it broken?” (D20).
struct SupportStatusSummary: Equatable, Sendable {
    let linkOK: Bool
    let lastUpdate: Date?
    let pendingSendCount: Int
    /// Local edits never require the peer online; only delivery does.
    let otherPhoneMustBeOpenForLocalEdit: Bool
    let deliveryDetail: String

    var linkStatusLine: String {
        linkOK ? "Link OK" : "Not linked or needs attention"
    }

    var lastUpdateLine: String {
        guard let lastUpdate else {
            return "Last update: not yet"
        }
        return "Last update: \(lastUpdate.formatted(date: .abbreviated, time: .shortened))"
    }

    var pendingLine: String {
        pendingSendCount == 0
            ? "Pending sends: none"
            : "Pending sends: \(pendingSendCount)"
    }

    var localEditLine: String {
        "Other phone not required online for local edit"
    }
}

/// Collapsed pairing steps for humans — never mirrors raw finalization enums.
enum UserPairingStep: Equatable, Sendable {
    case waitingForOtherPhone
    case waitingForYou
    case finishing
}

enum PairingBlockingActor: String, Equatable, Sendable {
    case you
    case otherPhone = "other phone"
    case background
}

struct UserPairingPresentation: Equatable, Sendable {
    let step: UserPairingStep
    let title: String
    let detail: String
    let blockingActor: PairingBlockingActor

    var voiceOverAnnouncement: String {
        switch blockingActor {
        case .you:
            "Waiting for you. \(title). \(detail)"
        case .otherPhone:
            "Waiting for the other iPhone. \(title). \(detail)"
        case .background:
            "Finishing in the background. \(title). \(detail)"
        }
    }
}

enum UserPairingPresentationBuilder {
    static func presentation(
        phase: SyncPhase,
        isHostApprovalPending: Bool,
        hasPairingReplicaConflict: Bool,
        finalizationState: PairingFinalizationState?,
        role: DeviceRole?,
        errorMessage: String?
    ) -> UserPairingPresentation {
        if hasPairingReplicaConflict {
            return UserPairingPresentation(
                step: .waitingForYou,
                title: "Combine task lists?",
                detail: errorMessage
                    ?? "Both copies are still on this iPhone. Review the preview, then combine them to finish the link.",
                blockingActor: .you
            )
        }

        if let errorMessage, phase == .failed {
            return UserPairingPresentation(
                step: .waitingForYou,
                title: "Needs attention",
                detail: errorMessage,
                blockingActor: .you
            )
        }

        switch phase {
        case .waitingForPeer:
            // Role-aware: joiners are already joining — never tell them to Join Existing Sync.
            if role == .joiner {
                return UserPairingPresentation(
                    step: .waitingForOtherPhone,
                    title: "Waiting for the main iPhone",
                    detail: "Stay on this screen. The main iPhone finishes the safety check and shares the task list.",
                    blockingActor: .otherPhone
                )
            }
            return UserPairingPresentation(
                step: .waitingForOtherPhone,
                title: "Waiting for the other iPhone",
                detail: "On the other iPhone, choose Join Existing Sync and scan the code or enter the phrase. This invitation is valid for 15 minutes.",
                blockingActor: .otherPhone
            )
        case .verifying:
            if isHostApprovalPending {
                return UserPairingPresentation(
                    step: .waitingForYou,
                    title: "Do these digits match?",
                    detail: "Confirm that the same six digits appear on both devices.",
                    blockingActor: .you
                )
            }
            return UserPairingPresentation(
                step: .waitingForOtherPhone,
                title: "Waiting for approval",
                detail: "The main iPhone must approve the matching safety code.",
                blockingActor: .otherPhone
            )
        case .provisioning:
            return UserPairingPresentation(
                step: .finishing,
                title: "Creating the private link",
                detail: "Got Done is preparing the shared task list securely.",
                blockingActor: .background
            )
        case .finalizing:
            return finalizingPresentation(
                state: finalizationState,
                role: role,
                errorMessage: errorMessage
            )
        case .connecting:
            return UserPairingPresentation(
                step: .finishing,
                title: "Connecting",
                detail: "Looking for your other iPhone.",
                blockingActor: .background
            )
        case .reconciling:
            return UserPairingPresentation(
                step: .finishing,
                title: "Catching up",
                detail: "Applying any changes saved while this iPhone was away.",
                blockingActor: .background
            )
        case .synced:
            return UserPairingPresentation(
                step: .finishing,
                title: "Private Sync is on",
                detail: ProductSyncPolicy.deliverySummary,
                blockingActor: .background
            )
        case .offline:
            return UserPairingPresentation(
                step: .finishing,
                title: "Sync will resume",
                detail: "Tasks stay safe on this iPhone. Upload continues when Got Done can reach the private mailbox.",
                blockingActor: .background
            )
        case .failed:
            return UserPairingPresentation(
                step: .waitingForYou,
                title: "Needs attention",
                detail: errorMessage ?? "Private Sync could not continue.",
                blockingActor: .you
            )
        case .unpaired:
            return UserPairingPresentation(
                step: .waitingForYou,
                title: "Not paired",
                detail: ProductSyncPolicy.twoDeviceBoundary,
                blockingActor: .you
            )
        }
    }

    private static func finalizingPresentation(
        state: PairingFinalizationState?,
        role: DeviceRole?,
        errorMessage: String?
    ) -> UserPairingPresentation {
        if let errorMessage {
            return UserPairingPresentation(
                step: .finishing,
                title: "Finishing the private link",
                detail: errorMessage,
                blockingActor: .background
            )
        }
        switch state {
        case .waitingForProvision:
            return UserPairingPresentation(
                step: .waitingForOtherPhone,
                title: "Waiting for the main iPhone",
                detail: "The secure handshake is saved. Waiting for the main iPhone to approve or decline.",
                blockingActor: .otherPhone
            )
        case .provisionMayHaveBeenStored:
            return UserPairingPresentation(
                step: .finishing,
                title: "Sharing the task list",
                detail: "Approval is saved. Got Done is making the shared list available to the other iPhone.",
                blockingActor: .background
            )
        case .provisionStagedAwaitingMergeApproval:
            return UserPairingPresentation(
                step: .waitingForYou,
                title: "Combine task lists?",
                detail: "Nothing is linked until you confirm how to combine both lists.",
                blockingActor: .you
            )
        case .readyMayHaveBeenStored:
            if role == .joiner {
                return UserPairingPresentation(
                    step: .waitingForOtherPhone,
                    title: "Waiting for confirmation",
                    detail: "This iPhone imported the shared list. Waiting for the main iPhone to confirm.",
                    blockingActor: .otherPhone
                )
            }
            return UserPairingPresentation(
                step: .finishing,
                title: "Confirming the imported list",
                detail: "The imported copy is safe. Waiting for encrypted confirmation.",
                blockingActor: .background
            )
        case .abortMayHaveBeenStored:
            return UserPairingPresentation(
                step: .finishing,
                title: "Cancelling pairing",
                detail: "No link will be created. Got Done is notifying the other iPhone.",
                blockingActor: .background
            )
        case .abortAcknowledgementMayHaveBeenStored:
            return UserPairingPresentation(
                step: .finishing,
                title: "Confirming cancellation",
                detail: "No link will be created. Cancellation is being acknowledged.",
                blockingActor: .background
            )
        case .commitMarkerMayHaveBeenStored, nil:
            return UserPairingPresentation(
                step: .finishing,
                title: "Finishing the private link",
                detail: "This step is saved and resumes the next time you open Got Done.",
                blockingActor: .background
            )
        }
    }
}
