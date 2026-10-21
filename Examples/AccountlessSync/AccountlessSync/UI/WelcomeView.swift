import GotSync
import SwiftUI

struct WelcomeView: View {
    @ObservedObject var model: SyncAppModel
    let joinAction: () -> Void
    let eraseAction: () -> Void
    var settingsAction: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack {
                        Spacer(minLength: 0)
                        if let settingsAction {
                            Button(action: settingsAction) {
                                Image(systemName: "gearshape")
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(RelayTheme.inkMuted)
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .accessibilityLabel("Settings")
                            .accessibilityIdentifier("open-settings")
                        }
                    }
                    .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Sync without\nan account.")
                            .font(.largeTitle.bold())
                            .tracking(-0.8)
                            .foregroundStyle(RelayTheme.ink)
                            .lineSpacing(0)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(
                            "Limited demo · up to \(ProductSyncPolicy.maxDevices) devices · E2E sync"
                        )
                        .font(.subheadline)
                        .foregroundStyle(RelayTheme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)

                    Spacer()

                    if model.phase != .failed, let reason = model.linkEndedReason {
                        LinkEndedNotice(reason: reason)
                            .relayCard(padding: 14)
                    }

                    Label(
                        ProductSyncPolicy.dataRecoveryDisclosure,
                        systemImage: "exclamationmark.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(RelayTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .relayCard(padding: 14)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("data-recovery-disclosure")

                    VStack(spacing: 10) {
                        Button {
                            model.createPrivateSync()
                        } label: {
                            Text("Create link")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        .pocPrimaryButtonStyle()
                        .controlSize(.large)
                        .accessibilityIdentifier("create-private-sync")
                        .accessibilityHint("Creates a one-time invitation on this iPhone.")

                        Button(action: joinAction) {
                            Text("Join link")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        .pocSecondaryButtonStyle()
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
                            "\(model.tasks.count) local \(model.tasks.count == 1 ? "task is" : "tasks are") still on this phone. Create a link here to bring a replacement phone in without losing \(model.tasks.count == 1 ? "it" : "them").",
                            systemImage: "iphone.and.arrow.forward"
                        )
                        .font(.footnote)
                        .foregroundStyle(RelayTheme.inkMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .relayCard(padding: 14)
                        .accessibilityElement(children: .combine)
                    }

                    if model.phase == .failed {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(
                                model.errorMessage
                                    ?? "Linking could not continue. Tasks already on this phone are still safe.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.subheadline)
                            .foregroundStyle(RelayTheme.danger)

                            Button("Create link") {
                                model.createPrivateSync()
                            }
                            .pocPrimaryButtonStyle()
                            .controlSize(.large)

                            Button("Erase local data…", role: .destructive) {
                                eraseAction()
                            }
                            .pocSecondaryButtonStyle()
                            .controlSize(.large)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .relayCard(padding: 14)
                    }

                    Text(ProductSyncPolicy.pairingKeepOpenSummary)
                        .font(RelayTheme.monoCaption)
                        .foregroundStyle(RelayTheme.inkMuted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 24)
                }
                .padding(.horizontal, 24)
                .frame(minHeight: geometry.size.height)
            }
        }
        .scrollIndicators(.hidden)
        .background(SoftFieldBackground())
        .preferredColorScheme(.dark)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
    }
}

struct POCGlassGroup<Content: View>: View {
    var spacing: CGFloat = 24
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

#if DEBUG
#Preview("Welcome") {
    @Previewable @StateObject var model = PreviewSupport.model()
    NavigationStack {
        WelcomeView(
            model: model,
            joinAction: {},
            eraseAction: {}
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("Welcome · local tasks") {
    @Previewable @StateObject var model = PreviewSupport.model(
        seedTaskTitles: ["Buy milk", "Ship demo"]
    )
    NavigationStack {
        WelcomeView(
            model: model,
            joinAction: {},
            eraseAction: {}
        )
    }
    .preferredColorScheme(.dark)
}
#endif

