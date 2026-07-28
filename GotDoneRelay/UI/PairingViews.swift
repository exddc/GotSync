import SwiftUI
import UIKit

struct PairingInvitationView: View {
    @ObservedObject var model: SyncAppModel
    let phrase: String
    let invitationURL: URL
    @State private var copiedPhrase = false

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

                    Label("One-time invitation", systemImage: "timer")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .relayCard()

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("17-word phrase")
                            .font(.headline)
                        Spacer()
                        Button {
                            UIPasteboard.general.setItems(
                                [["public.utf8-plain-text": phrase]],
                                options: [
                                    .localOnly: true,
                                    .expirationDate: Date().addingTimeInterval(120),
                                ]
                            )
                            copiedPhrase = true
                        } label: {
                            Label(
                                copiedPhrase ? "Copied" : "Copy",
                                systemImage: copiedPhrase ? "checkmark" : "doc.on.doc"
                            )
                        }
                        .font(.subheadline.weight(.semibold))
                        .accessibilityLabel(
                            copiedPhrase ? "Phrase copied" : "Copy invitation phrase"
                        )
                    }

                    Text(phrase)
                        .font(.system(.subheadline, design: .monospaced))
                        .lineSpacing(5)
                        .accessibilityIdentifier("invitation-phrase")
                }
                .relayCard()

                SyncStatusView(
                    phase: model.phase,
                    title: model.statusTitle,
                    detail: model.statusDetail,
                    roundTripMilliseconds: nil,
                    lastSyncedAt: nil
                )

                Button("Cancel Pairing", role: .cancel) {
                    model.cancelPairing()
                }
                .frame(maxWidth: .infinity)
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
}

struct PairingProgressView: View {
    @ObservedObject var model: SyncAppModel

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            ZStack {
                Circle()
                    .fill(RelayTheme.accent.opacity(0.10))
                    .frame(width: 112, height: 112)
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(RelayTheme.accent)
            }
            .accessibilityHidden(true)

            VStack(spacing: 10) {
                ProgressView()
                Text(model.statusTitle)
                    .font(.title2.weight(.bold))
                Text(model.statusDetail)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PrivacyDisclosureView(compact: true)

            Spacer()

            Button("Cancel Pairing", role: .cancel) {
                model.cancelPairing()
            }
            .accessibilityIdentifier("cancel-pairing")
        }
        .padding(24)
        .navigationTitle("Private Sync")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SafetyCodeView: View {
    @ObservedObject var model: SyncAppModel
    let code: String
    @ScaledMetric(relativeTo: .largeTitle) private var codeFontSize = 50.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PairingHeaderView(
                    eyebrow: "Safety check",
                    title: "Do these digits match?",
                    detail: "Compare this code with the other iPhone. A matching code confirms that nobody altered the encrypted setup.",
                    symbol: "checkmark.shield.fill"
                )

                Text(formattedCode)
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
                    detail: model.statusDetail,
                    roundTripMilliseconds: nil,
                    lastSyncedAt: nil
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

                Button("Cancel Pairing", role: .cancel) {
                    model.cancelPairing()
                }
                .frame(maxWidth: .infinity)
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
}
