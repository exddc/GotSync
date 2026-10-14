import GotSync
import SwiftUI
import UIKit

struct PairingInvitationView: View {
    @ObservedObject var model: SyncAppModel
    let phrase: String
    let invitationURL: URL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PairingHeaderView(
                    title: model.isIssuingGroupInvite
                        ? "Invite another phone"
                        : "Show this code",
                    detail: model.isIssuingGroupInvite
                        ? "On the other phone, tap Join link and scan. \(ProductSyncPolicy.sharedAccessDisclosure)"
                        : "On the other phone, tap Join link and scan. Use the phrase only if the camera is unavailable.",
                    symbol: "qrcode"
                )

                VStack(spacing: 14) {
                    QRCodeView(url: invitationURL)
                        .frame(width: 220, height: 220)
                        .accessibilityLabel("Sync invitation QR code")

                    if let expiresAt = model.invitationExpiresAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(remainingText(until: expiresAt, now: context.date))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(RelayTheme.inkMuted)
                                .accessibilityLabel(
                                    "Invitation expires at \(expiresAt.formatted(date: .omitted, time: .shortened))"
                                )
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .relayCard(padding: 20)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Phrase")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RelayTheme.inkMuted)
                        .textCase(.uppercase)
                        .tracking(0.6)

                    Text(phrase)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(RelayTheme.ink)
                        .lineSpacing(5)
                        .accessibilityIdentifier("invitation-phrase")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .relayCard(padding: 16)

                Button {
                    model.regenerateInvitation()
                } label: {
                    HStack(alignment: .center, spacing: 8) {
                        Image(systemName: "arrow.clockwise")
                        
                        Text("New code")
                            
                    }
                    .frame(maxWidth: .infinity)
                }
                .pocSecondaryButtonStyle()
                .controlSize(.large)
                .accessibilityHint(
                    "Invalidates this invitation and creates a new one."
                )
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .background(SoftFieldBackground())
        .navigationTitle("Link")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    model.cancelPairing()
                }
                .accessibilityIdentifier("cancel-pairing")
            }
        }
    }

    private func remainingText(until expiresAt: Date, now: Date) -> String {
        let seconds = max(0, Int(expiresAt.timeIntervalSince(now).rounded(.up)))
        if seconds >= 60 {
            let minutes = (seconds + 59) / 60
            return minutes == 1
                ? "Expires in about 1 minute"
                : "Expires in about \(minutes) minutes"
        }
        return seconds == 1
            ? "Expires in 1 second"
            : "Expires in \(seconds) seconds"
    }
}

struct PairingProgressView: View {
    @ObservedObject var model: SyncAppModel
    @State private var lastAccessibilityAnnouncement: String?
    @State private var isConflictConfirmationPresented = false

    var body: some View {
        ScrollView {
            VStack(spacing: model.hasPairingReplicaConflict ? 16 : 28) {
                PairingLinkMark(
                    isAnimating: !model.hasPairingReplicaConflict,
                    compact: model.hasPairingReplicaConflict
                )
                .accessibilityHidden(true)

                VStack(spacing: 10) {
                    if model.hasPairingReplicaConflict {
                        Image(systemName: "rectangle.on.rectangle.angled")
                            .font(.title3)
                            .foregroundStyle(RelayTheme.pending)
                            .accessibilityHidden(true)
                    }
                    Text(model.statusTitle)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(RelayTheme.ink)
                        .multilineTextAlignment(.center)
                    Text(model.statusDetail)
                        .font(.body)
                        .foregroundStyle(RelayTheme.inkMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    if !model.hasPairingReplicaConflict {
                        UserPairingStepIndicator(
                            step: model.userPairingPresentation.step
                        )
                        .padding(.top, 6)
                    }
                }

                if model.hasPairingReplicaConflict {
                    VStack(spacing: 12) {
                        if let preview = model.keepBothPreview {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("What combining will do")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(RelayTheme.ink)
                                Text(preview.confirmationSummary)
                                    .font(.footnote)
                                    .foregroundStyle(RelayTheme.inkMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .relayCard(padding: 14)
                            .accessibilityIdentifier("keep-both-preview")
                        } else {
                            Text(
                                "Both copies are still on this phone. This POC checks the combined list before either phone commits."
                            )
                            .font(.footnote)
                            .foregroundStyle(RelayTheme.inkMuted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        Button("Combine and finish…") {
                            isConflictConfirmationPresented = true
                        }
                        .pocPrimaryButtonStyle()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier(
                            "resolve-conflicted-pairing"
                        )

                    }
                } else if !model.canCancelPairing {
                    Text(
                        "This step is saved. You can leave; it resumes the next time you open Accountless Sync."
                    )
                    .font(.footnote)
                    .foregroundStyle(RelayTheme.inkMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pairing-finalization-saved")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.vertical, model.hasPairingReplicaConflict ? 16 : 28)
        }
        .background(SoftFieldBackground())
        .navigationTitle("Linking")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.canCancelPairing {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.cancelPairing()
                    }
                    .accessibilityIdentifier("cancel-pairing")
                }
            }
        }
        .confirmationDialog(
            "Combine task lists?",
            isPresented: $isConflictConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Combine and finish") {
                model.resolvePairingReplicaConflictKeepingBoth()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                model.keepBothPreview?.confirmationSummary
                    ?? "Matching tasks are kept once; local-only tasks are added. Conflicting versions may appear twice. Cancel leaves this phone unchanged."
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

private struct PairingLinkMark: View {
    var isAnimating: Bool
    var compact: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isActive = false

    private var size: CGFloat { compact ? 72 : 96 }
    private var iconSize: CGFloat { compact ? 28 : 36 }

    var body: some View {
        let motion = isAnimating && !reduceMotion
        ZStack {

            Image(systemName: "link")
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(RelayTheme.accent)
                .rotationEffect(.degrees(motion && isActive ? 10 : -10))
                .scaleEffect(motion && isActive ? 1.04 : 1.0)
        }
        .onAppear { syncMotion() }
        .onChange(of: isAnimating) { _, _ in syncMotion() }
        .onChange(of: reduceMotion) { _, _ in syncMotion() }
    }

    private func syncMotion() {
        let shouldRun = isAnimating && !reduceMotion
        guard shouldRun else {
            withAnimation(.easeOut(duration: 0.2)) {
                isActive = false
            }
            return
        }
        isActive = false
        withAnimation(
            .easeInOut(duration: 1.6).repeatForever(autoreverses: true)
        ) {
            isActive = true
        }
    }
}

struct UserPairingStepIndicator: View {
    let step: UserPairingStep

    var body: some View {
        HStack(spacing: 6) {
            stepDot(active: step == .waitingForOtherPhone || step == .waitingForYou || step == .finishing)
            stepDot(active: step == .waitingForYou || step == .finishing)
            stepDot(active: step == .finishing)
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

    private func stepDot(active: Bool) -> some View {
        Capsule()
            .fill(active ? RelayTheme.accent : RelayTheme.inkMuted.opacity(0.22))
            .frame(width: active ? 20 : 8, height: 4)
            .animation(RelayTheme.springSnappy, value: active)
    }
}

struct SafetyCodeView: View {
    @ObservedObject var model: SyncAppModel
    let code: String
    @ScaledMetric(relativeTo: .largeTitle) private var codeFontSize = 52.0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                PairingHeaderView(
                    title: "Do these match?",
                    detail: ProductSyncPolicy.safetyCodeDetail,
                    symbol: "checkmark.shield"
                )

                Text(displayCode)
                    .font(
                        .system(
                            size: codeFontSize,
                            weight: .bold,
                            design: .monospaced
                        )
                    )
                    .foregroundStyle(RelayTheme.ink)
                    .minimumScaleFactor(0.75)
                    .tracking(4)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                    .relayCard(padding: 20)
                    .accessibilityLabel("Safety code \(code.map(String.init).joined(separator: " "))")
                    .accessibilityIdentifier("safety-code")

                if model.isHostApprovalPending {
                    Button {
                        model.approveSafetyCode()
                    } label: {
                        Text("Codes match. Approve")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .pocPrimaryButtonStyle()
                    .controlSize(.large)
                    .accessibilityIdentifier("approve-safety-code")
                } else {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(
                            model.phase == .provisioning
                                ? "Importing the shared list…"
                                : "Waiting for the other phone to approve…"
                        )
                        .font(.footnote)
                        .foregroundStyle(RelayTheme.inkMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                Button("Codes don’t match", role: .destructive) {
                    model.rejectSafetyCode()
                }
                .pocSecondaryButtonStyle()
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .accessibilityHint(
                    "Cancels pairing without linking either iPhone."
                )
                .accessibilityIdentifier("reject-safety-code")
            }
            .padding(22)
        }
        .scrollIndicators(.hidden)
        .background(SoftFieldBackground())
        .navigationTitle("Verify")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    model.cancelPairing()
                }
                .accessibilityIdentifier("cancel-pairing")
            }
        }
    }

    private var formattedCode: String {
        let digits = code.filter(\.isNumber)
        guard digits.count > 3 else {
            return digits
        }
        let splitIndex = digits.index(digits.startIndex, offsetBy: 3)
        return "\(digits[..<splitIndex])  \(digits[splitIndex...])"
    }

    private var displayCode: String {
        dynamicTypeSize.isAccessibilitySize
            ? formattedCode.replacingOccurrences(of: "  ", with: "\n")
            : formattedCode
    }
}

#if DEBUG
#Preview("Invitation") {
    @Previewable @StateObject var model = PreviewSupport.model()
    NavigationStack {
        PairingInvitationView(
            model: model,
            phrase: PreviewSupport.samplePhrase,
            invitationURL: PreviewSupport.sampleInvitationURL
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("Pairing progress") {
    @Previewable @StateObject var model = PreviewSupport.model()
    NavigationStack {
        PairingProgressView(model: model)
    }
    .preferredColorScheme(.dark)
}

#Preview("Pairing link mark") {
    PairingLinkMark(isAnimating: true, compact: false)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SoftFieldBackground())
        .preferredColorScheme(.dark)
}

#Preview("Safety code") {
    @Previewable @StateObject var model = PreviewSupport.model()
    NavigationStack {
        SafetyCodeView(
            model: model,
            code: PreviewSupport.sampleSafetyCode
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("Pairing steps") {
    VStack(spacing: 24) {
        UserPairingStepIndicator(step: .waitingForOtherPhone)
        UserPairingStepIndicator(step: .waitingForYou)
        UserPairingStepIndicator(step: .finishing)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(SoftFieldBackground())
    .preferredColorScheme(.dark)
}
#endif

