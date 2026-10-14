import GotSync
import SwiftUI

struct ManageSyncView: View {
    @ObservedObject var model: SyncAppModel
    @Binding var isUnlinkConfirmationPresented: Bool
    @Environment(\.dismiss) private var dismiss

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

                Section("Linked phones") {
                    ForEach(
                        Array(model.linkedMemberLabels.enumerated()),
                        id: \.offset
                    ) { _, label in
                        Label(label, systemImage: "iphone")
                    }
                    Text(
                        "\(model.linkedMemberCount) of \(ProductSyncPolicy.maxDevices)"
                    )
                    .font(.footnote)
                    .foregroundStyle(RelayTheme.inkMuted)
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
                    Text("Live relay: \(model.relayURL.host() ?? "local")")
                    Text("Mailbox: \(model.mailboxURL.host() ?? "local")")
                    if let error = model.mailboxErrorMessage {
                        Text("Mailbox error: \(error)")
                    }
                }
                #endif
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

