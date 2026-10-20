import GotSync
import SwiftUI

struct ManageSyncView: View {
    @ObservedObject var model: SyncAppModel
    @Binding var isUnlinkConfirmationPresented: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var deviceToRemove: LinkedDevice?

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    Text(model.manageSyncStatusLine)
                        .font(.body.weight(.medium))
                        .foregroundStyle(RelayTheme.ink)
                    Text(ProductSyncPolicy.sharedAccessDisclosure)
                        .font(.footnote)
                        .foregroundStyle(RelayTheme.inkMuted)
                        .accessibilityIdentifier("shared-access-disclosure")
                    Text(ProductSyncPolicy.deliverySummary)
                        .font(.footnote)
                        .foregroundStyle(RelayTheme.inkMuted)
                }

                Section("Data recovery") {
                    Text(ProductSyncPolicy.dataRecoveryDisclosure)
                        .font(.footnote)
                        .foregroundStyle(RelayTheme.inkMuted)
                        .accessibilityIdentifier("data-recovery-disclosure")
                }

                Section {
                    ForEach(model.snapshot.linkedDevices) { device in
                        linkedDeviceRow(device)
                    }
                    Text(
                        "\(model.linkedMemberCount) of \(ProductSyncPolicy.maxDevices)"
                    )
                    .font(.footnote)
                    .foregroundStyle(RelayTheme.inkMuted)
                } header: {
                    Text("Linked phones")
                } footer: {
                    if model.linkedMemberCount > 1 {
                        Text(ProductSyncPolicy.removePhoneDetail)
                    }
                }

                Section {
                    if model.isGroupAtCapacity {
                        Text(ProductSyncPolicy.groupFullMessage)
                            .font(.subheadline)
                            .foregroundStyle(RelayTheme.inkMuted)
                            .accessibilityIdentifier("group-full-message")
                    } else {
                        Button {
                            dismiss()
                            model.inviteToGroup()
                        } label: {
                            Label(
                                ProductSyncPolicy.inviteAnotherIPhone,
                                systemImage: "qrcode"
                            )
                        }
                        .accessibilityIdentifier("invite-another-iphone")
                    }
                } footer: {
                    Text(ProductSyncPolicy.inviteDetail)
                }

                Section {
                    Button(role: .destructive) {
                        isUnlinkConfirmationPresented = true
                        dismiss()
                    } label: {
                        Label(
                            ProductSyncPolicy.leaveSyncTitle,
                            systemImage: "link.badge.minus"
                        )
                    }
                    .accessibilityIdentifier("leave-sync")
                } footer: {
                    Text(ProductSyncPolicy.leaveSyncDetail)
                }

                #if DEBUG
                Section("Diagnostics") {
                    Text("Members: \(model.linkedMemberCount)")
                    Text("Sync service: \(model.mailboxURL.host() ?? "local")")
                    Text("Pairing relay: \(model.relayURL.host() ?? "local")")
                    if let error = model.mailboxErrorMessage {
                        Text("Last sync error: \(error)")
                    }
                }
                #endif
            }
            .confirmationDialog(
                ProductSyncPolicy.removePhoneTitle,
                isPresented: Binding(
                    get: { deviceToRemove != nil },
                    set: { if !$0 { deviceToRemove = nil } }
                ),
                titleVisibility: .visible,
                presenting: deviceToRemove
            ) { device in
                Button(ProductSyncPolicy.removePhoneTitle, role: .destructive) {
                    model.removeDevice(device)
                }
                .accessibilityIdentifier("confirm-remove-phone")
            } message: { device in
                Text(SyncAppModel.label(for: device))
            }
            .navigationTitle(ProductSyncPolicy.manageSyncTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func linkedDeviceRow(_ device: LinkedDevice) -> some View {
        HStack {
            Label(SyncAppModel.label(for: device), systemImage: "iphone")
            Spacer()
            if device.isRemovalPending {
                Text(ProductSyncPolicy.removingPhoneLabel)
                    .font(.footnote)
                    .foregroundStyle(RelayTheme.inkMuted)
            } else if !device.isCurrentDevice {
                Button(ProductSyncPolicy.removePhoneTitle, role: .destructive) {
                    deviceToRemove = device
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
                .accessibilityIdentifier("remove-phone-\(device.shortFingerprint)")
            }
        }
    }
}

#if DEBUG
#Preview("Manage sync") {
    @Previewable @StateObject var model = PreviewSupport.model()
    ManageSyncView(
        model: model,
        isUnlinkConfirmationPresented: .constant(false)
    )
    .preferredColorScheme(.dark)
}
#endif

