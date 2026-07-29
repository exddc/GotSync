import SwiftUI

struct WelcomeView: View {
    @ObservedObject var model: SyncAppModel
    let joinAction: () -> Void
    let eraseAction: () -> Void

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
                    .disabled(!model.canJoinExistingSync)
                    .accessibilityIdentifier("join-private-sync")
                    .accessibilityHint(
                        model.canJoinExistingSync
                            ? "Opens the phrase and QR code join options."
                            : "Disabled until local storage is available."
                    )
                }

                if !model.tasks.isEmpty {
                    Label(
                        "\(model.tasks.count) local \(model.tasks.count == 1 ? "task is" : "tasks are") still saved here. To link a replacement phone without losing \(model.tasks.count == 1 ? "it" : "them"), create Private Sync on this iPhone.",
                        systemImage: "iphone.and.arrow.forward"
                    )
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .relayCard()
                    .accessibilityElement(children: .combine)
                }

                if model.phase == .failed {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(
                            model.errorMessage
                                ?? "The connection ended unexpectedly.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.subheadline)
                        .foregroundStyle(.red)

                        Button("Erase Local Data…", role: .destructive) {
                            eraseAction()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .relayCard()
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
