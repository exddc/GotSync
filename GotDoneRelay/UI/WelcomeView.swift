import SwiftUI

struct WelcomeView: View {
    @ObservedObject var model: SyncAppModel
    let joinAction: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your tasks.")
                        .font(.system(.title, design: .rounded, weight: .regular))
                    Text("On your devices.")
                        .font(.system(.title, design: .rounded, weight: .regular))
                    Text("No account.")
                        .font(.system(.title, design: .rounded, weight: .black))
                        .foregroundStyle(RelayTheme.accent)
                }
                .padding(.top, 12)
                .accessibilityElement(children: .combine)

                Text(
                    "Link two iPhones with a one-time phrase or QR code. Changes travel end-to-end encrypted."
                )
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 10) {
                    Button {
                        model.createPrivateSync()
                    } label: {
                        Label("Create Private Sync", systemImage: "qrcode")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 3)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("create-private-sync")
                    .accessibilityHint("Creates a one-time invitation on this iPhone.")

                    Button(action: joinAction) {
                        Label("Join Existing Sync", systemImage: "viewfinder")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 3)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier("join-private-sync")
                    .accessibilityHint("Opens the phrase and QR code join options.")
                }

                if model.phase == .failed {
                    Label(
                        model.errorMessage ?? "The connection ended unexpectedly.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .relayCard()
                    .accessibilityElement(children: .combine)
                }

                PrivacyDisclosureView()

                Label(
                    "Keep both apps open while you pair them the first time.",
                    systemImage: "iphone.gen3.radiowaves.left.and.right"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
                .padding(.bottom, 12)
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Got Done")
        .navigationBarTitleDisplayMode(.inline)
    }
}
