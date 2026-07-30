import SwiftUI
import UIKit

struct PairingInvitationView: View {
    @ObservedObject var model: SyncAppModel
    let phrase: String
    let invitationURL: URL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PairingHeaderView(
                    eyebrow: model.isIssuingGroupInvite
                        ? "Invite to this sync"
                        : "Main iPhone",
                    title: model.isIssuingGroupInvite
                        ? "Invite another iPhone"
                        : "Start a private sync",
                    detail: model.isIssuingGroupInvite
                        ? "\(ProductSyncPolicy.inviteDetail) On the other iPhone, tap Join Existing Sync and scan this code."
                        : "On the other iPhone, tap Join Existing Sync and scan this code. Enter the phrase only if the camera is unavailable. Invitation valid for 15 minutes. \(ProductSyncPolicy.multiDeviceBoundary)",
                    symbol: "iphone.gen3.radiowaves.left.and.right"
                )

                VStack(spacing: 12) {
                    QRCodeView(url: invitationURL)
                        .frame(width: 196, height: 196)
                        .accessibilityLabel("Private sync invitation QR code")

                    if let expiresAt = model.invitationExpiresAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Label(
                                remainingText(until: expiresAt, now: context.date),
                                systemImage: "timer"
                            )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(
                                "Invitation expires at \(expiresAt.formatted(date: .omitted, time: .shortened))"
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .relayCard()

                VStack(alignment: .leading, spacing: 12) {
                    Text("17-word phrase")
                        .font(.headline)

                    Text(phrase)
                        .font(.system(.subheadline, design: .monospaced))
                        .lineSpacing(5)
                        .accessibilityIdentifier("invitation-phrase")
                }
                .relayCard()

                Button {
                    model.regenerateInvitation()
                } label: {
                    Label("Generate New Code", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityHint(
                    "Invalidates this invitation and creates a new one."
                )

                SyncStatusView(
                    phase: model.phase,
                    title: model.statusTitle,
                    detail: model.statusDetail
                )

                Button("Cancel Pairing", role: .cancel) {
                    model.cancelPairing()
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .padding(.bottom, 16)
                .accessibilityIdentifier("cancel-pairing")
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Private Sync")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func remainingText(until expiresAt: Date, now: Date) -> String {
        let seconds = max(0, Int(expiresAt.timeIntervalSince(now).rounded(.up)))
        if seconds >= 60 {
            let minutes = (seconds + 59) / 60
            return minutes == 1
                ? "Invitation expires in about 1 minute"
                : "Invitation expires in about \(minutes) minutes"
        }
        return seconds == 1
            ? "Invitation expires in 1 second"
            : "Invitation expires in \(seconds) seconds"
    }
}

struct PairingProgressView: View {
    @ObservedObject var model: SyncAppModel
    @State private var lastAccessibilityAnnouncement: String?
    @State private var isConflictConfirmationPresented = false

    var body: some View {
        ScrollView {
            VStack(spacing: model.hasPairingReplicaConflict ? 16 : 24) {
                ZStack {
                    Circle()
                        .fill(RelayTheme.accent.opacity(0.10))
                        .frame(
                            width: model.hasPairingReplicaConflict ? 80 : 112,
                            height: model.hasPairingReplicaConflict ? 80 : 112
                        )
                    Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                        .font(
                            .system(
                                size: model.hasPairingReplicaConflict ? 32 : 42,
                                weight: .medium
                            )
                        )
                        .foregroundStyle(RelayTheme.accent)
                }
                .accessibilityHidden(true)

                VStack(spacing: 10) {
                    if model.hasPairingReplicaConflict {
                        Image(systemName: "rectangle.on.rectangle.angled")
                            .font(.title2)
                            .foregroundStyle(RelayTheme.warning)
                            .accessibilityHidden(true)
                    } else {
                        ProgressView()
                    }
                    Text(model.statusTitle)
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text(model.statusDetail)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    if !model.hasPairingReplicaConflict {
                        UserPairingStepIndicator(
                            step: model.userPairingPresentation.step
                        )
                    }
                }

                PrivacyDisclosureView(compact: true)

                if model.hasPairingReplicaConflict {
                    VStack(spacing: 12) {
                        if let preview = model.keepBothPreview {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("What combining will do")
                                    .font(.headline)
                                Text(preview.confirmationSummary)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .relayCard()
                            .accessibilityIdentifier("keep-both-preview")
                        } else {
                            Text(
                                "Both copies are still on this iPhone. Got Done checks the complete combined list before either phone commits to the link."
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        Button("Combine Task Lists and Finish…") {
                            isConflictConfirmationPresented = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier(
                            "resolve-conflicted-pairing"
                        )

                        if model.canCancelPairing {
                            Button("Cancel Pairing", role: .cancel) {
                                model.cancelPairing()
                            }
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("cancel-pairing")
                        }
                    }
                } else if model.canCancelPairing {
                    Button("Cancel Pairing", role: .cancel) {
                        model.cancelPairing()
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("cancel-pairing")
                } else {
                    Label(
                        "This step is saved. You can leave Got Done; it resumes the next time you open it.",
                        systemImage: "arrow.clockwise.icloud"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pairing-finalization-saved")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, model.hasPairingReplicaConflict ? 16 : 24)
        }
        .navigationTitle("Private Sync")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Combine task lists?",
            isPresented: $isConflictConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Combine and Finish") {
                model.resolvePairingReplicaConflictKeepingBoth()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                model.keepBothPreview?.confirmationSummary
                    ?? "Got Done keeps matching tasks once, adds local-only tasks, and may show conflicting versions twice. Cancel leaves this iPhone unchanged."
            )
        }
        .onAppear {
            announceFinalizationStatus(model.finalizationAnnouncement)
        }
        .onChange(of: model.finalizationAnnouncement) { _, announcement in
            announceFinalizationStatus(announcement)
        }
    }

    private func announceFinalizationStatus(_ announcement: String?) {
        guard
            let announcement,
            announcement != lastAccessibilityAnnouncement
        else {
            return
        }
        lastAccessibilityAnnouncement = announcement
        UIAccessibility.post(
            notification: .announcement,
            argument: announcement
        )
    }
}

struct UserPairingStepIndicator: View {
    let step: UserPairingStep

    var body: some View {
        HStack(spacing: 8) {
            stepChip("1", title: "Other phone", active: step == .waitingForOtherPhone)
            stepChip("2", title: "You", active: step == .waitingForYou)
            stepChip("3", title: "Finish", active: step == .finishing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch step {
        case .waitingForOtherPhone:
            "Step 1 of 3: waiting for the other phone"
        case .waitingForYou:
            "Step 2 of 3: waiting for you"
        case .finishing:
            "Step 3 of 3: finishing"
        }
    }

    private func stepChip(
        _ number: String,
        title: String,
        active: Bool
    ) -> some View {
        VStack(spacing: 4) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(active ? .white : .secondary)
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(active ? RelayTheme.accent : Color.secondary.opacity(0.18))
                )
            Text(title)
                .font(.caption2.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? .primary : .secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct SafetyCodeView: View {
    @ObservedObject var model: SyncAppModel
    let code: String
    @ScaledMetric(relativeTo: .largeTitle) private var codeFontSize = 50.0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PairingHeaderView(
                    eyebrow: "Safety check",
                    title: "Do these digits match?",
                    detail: "Compare this code with the other iPhone. A matching code confirms that nobody altered setup.",
                    symbol: "checkmark.shield.fill"
                )

                Text(displayCode)
                    .font(
                        .system(
                            size: codeFontSize,
                            weight: .bold,
                            design: .monospaced
                        )
                    )
                    .minimumScaleFactor(0.75)
                    .tracking(3)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .relayCard()
                    .accessibilityLabel("Safety code \(code.map(String.init).joined(separator: " "))")
                    .accessibilityIdentifier("safety-code")

                SyncStatusView(
                    phase: model.phase,
                    title: model.statusTitle,
                    detail: model.statusDetail
                )

                if model.isHostApprovalPending {
                    Button {
                        model.approveSafetyCode()
                    } label: {
                        Label("Codes Match — Approve", systemImage: "checkmark.shield.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("approve-safety-code")
                } else {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(
                            model.phase == .provisioning
                                ? "Importing the shared task list…"
                                : "Waiting for approval on the main iPhone…"
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }

                Button("Codes Don’t Match", role: .destructive) {
                    model.rejectSafetyCode()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .accessibilityHint(
                    "Cancels pairing without linking either iPhone."
                )
                .accessibilityIdentifier("reject-safety-code")

                Button("Cancel Pairing", role: .cancel) {
                    model.cancelPairing()
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .accessibilityIdentifier("cancel-pairing")
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Verify Link")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var formattedCode: String {
        let digits = code.filter(\.isNumber)
        guard digits.count > 3 else {
            return digits
        }
        let splitIndex = digits.index(digits.startIndex, offsetBy: 3)
        return "\(digits[..<splitIndex]) \(digits[splitIndex...])"
    }

    private var displayCode: String {
        dynamicTypeSize.isAccessibilitySize
            ? formattedCode.replacingOccurrences(of: " ", with: "\n")
            : formattedCode
    }
}
