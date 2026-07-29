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
                    eyebrow: "Main iPhone",
                    title: "Pair a second iPhone",
                    detail: "On the other iPhone, tap Join Existing Sync and scan this code or enter the phrase.",
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
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title2)
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                    } else {
                        ProgressView()
                    }
                    Text(model.statusTitle)
                        .font(.title2.weight(.bold))
                    Text(model.statusDetail)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                PrivacyDisclosureView(compact: true)

                if model.hasPairingReplicaConflict {
                    VStack(spacing: 12) {
                        Text(
                            "Both copies are still on this iPhone. Got Done checks the complete combined copy before either phone commits to the link."
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                        Button("Keep Both Task Lists and Finish…") {
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
                        "This encrypted step is saved. You can close Got Done. It resumes the next time you open it.",
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
            "Keep both task lists and finish?",
            isPresented: $isConflictConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Keep Both and Finish") {
                model.resolvePairingReplicaConflictKeepingBoth()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Got Done keeps the main iPhone’s archive, reuses unchanged tasks, and adds local-only or conflicting tasks with their completion state. Conflicting versions may appear twice."
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
                    detail: "Compare this code with the other iPhone. A matching code confirms that nobody altered the encrypted setup.",
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
                                ? "Importing the encrypted task archive…"
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
