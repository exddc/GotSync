import GotSync
import SwiftUI

@MainActor
struct ContentView: View {
    @State private var configuration: SyncEndpointConfiguration?
    @State private var configurationError: String?
    @State private var sessionID = UUID()

    init(bundle: Bundle = .main) {
        let loaded = Self.loadConfiguration(bundle: bundle)
        _configuration = State(initialValue: loaded.configuration)
        _configurationError = State(initialValue: loaded.error)
    }

    var body: some View {
        if let configuration {
            SyncRootView(
                configuration: configuration,
                onConfigurationChange: { newConfiguration in
                    self.configuration = newConfiguration
                    self.configurationError = nil
                    self.sessionID = UUID()
                }
            )
            .id(sessionID)
        } else {
            SyncConfigurationFailureView(
                message: configurationError
                    ?? "This build is missing secure sync endpoints."
            )
        }
    }

    private static func loadConfiguration(
        bundle: Bundle = .main
    ) -> (configuration: SyncEndpointConfiguration?, error: String?) {
        do {
            return (try SyncEndpointConfiguration.load(bundle: bundle), nil)
        } catch {
            return (nil, displayMessage(for: error))
        }
    }

    private static func displayMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription
        {
            return description
        }
        return "This build cannot start private sync."
    }
}

@MainActor
private struct SyncRootView: View {
    let configuration: SyncEndpointConfiguration
    let onConfigurationChange: (SyncEndpointConfiguration) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var model: SyncAppModel
    @State private var presentedSheet: RelaySheet?
    @State private var isResetConfirmationPresented = false
    @State private var isUnlinkConfirmationPresented = false

    init(
        configuration: SyncEndpointConfiguration,
        onConfigurationChange: @escaping (SyncEndpointConfiguration) -> Void
    ) {
        self.configuration = configuration
        self.onConfigurationChange = onConfigurationChange
        _model = StateObject(
            wrappedValue: SyncAppModel(
                relayURL: configuration.relayURL,
                mailboxURL: configuration.mailboxURL
            )
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if let safetyCode = model.safetyCode {
                    SafetyCodeView(model: model, code: safetyCode)
                } else if model.isPairingFinalizationLocked {
                    PairingProgressView(model: model)
                } else if let phrase = model.invitationPhrase,
                          let invitationURL = model.invitationURL
                {
                    PairingInvitationView(
                        model: model,
                        phrase: phrase,
                        invitationURL: invitationURL
                    )
                } else if model.isPaired {
                    TaskDashboardView(
                        model: model,
                        isResetConfirmationPresented: $isResetConfirmationPresented,
                        isUnlinkConfirmationPresented: $isUnlinkConfirmationPresented,
                        joinAction: { presentedSheet = .join },
                        settingsAction: developerSettingsAction
                    )
                } else if model.phase == .waitingForPeer
                            || model.phase == .provisioning
                            || model.phase == .finalizing
                {
                    PairingProgressView(model: model)
                } else if model.hasLocalReplicaHistory {
                    TaskDashboardView(
                        model: model,
                        isResetConfirmationPresented: $isResetConfirmationPresented,
                        isUnlinkConfirmationPresented: $isUnlinkConfirmationPresented,
                        joinAction: { presentedSheet = .join },
                        settingsAction: developerSettingsAction
                    )
                } else {
                    WelcomeView(
                        model: model,
                        joinAction: { presentedSheet = .join },
                        eraseAction: {
                            isResetConfirmationPresented = true
                        },
                        settingsAction: developerSettingsAction
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SoftFieldBackground())
            .animation(
                reduceMotion ? nil : RelayTheme.springSoft,
                value: model.phase
            )
        }
        .tint(RelayTheme.accent)
        .preferredColorScheme(.dark)
        .sheet(item: $presentedSheet) { destination in
            switch destination {
            case .join:
                JoinSyncSheet(model: model)
            case .settings:
                DeveloperSettingsView(
                    currentRelayURL: model.relayURL,
                    onRelayURLApplied: applyRelayURL
                )
            }
        }
        .confirmationDialog(
            "Erase all local data?",
            isPresented: $isResetConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Erase all local data", role: .destructive) {
                model.eraseLocalData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This removes the pairing keys and every task on this iPhone. The other phone is not erased."
            )
        }
        .confirmationDialog(
            model.pairingRecoveryResetRequired
                ? "Keep tasks · reset link?"
                : "Unlink this phone?",
            isPresented: $isUnlinkConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(
                model.pairingRecoveryResetRequired
                    ? "Keep tasks · reset link"
                    : "Unlink and keep tasks"
            ) {
                if model.pairingRecoveryResetRequired {
                    model.unlinkAndKeepTasks()
                } else {
                    model.leaveGroupAndKeepTasks()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                model.pairingRecoveryResetRequired
                    ? "Tasks stay on this phone. Unfinished pairing recovery is cleared so you can create a link again. Erase is not required."
                    : ProductSyncPolicy.leaveSyncDetail
            )
        }
        .onOpenURL { url in
            model.joinPrivateSync(url: url)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                model.applicationDidBecomeActive()
            case .background:
                model.applicationDidEnterBackground()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }

    private var developerSettingsAction: (() -> Void)? {
        #if DEBUG
        { presentedSheet = .settings }
        #else
        nil
        #endif
    }

    private func applyRelayURL(_ relayURL: URL) {
        do {
            let next = try configuration.replacingRelayURL(relayURL)
            onConfigurationChange(next)
        } catch {
            // Validation already ran in DeveloperSettingsView.
        }
    }
}

private struct SyncConfigurationFailureView: View {
    let message: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Build needs configuration", systemImage: "wrench.and.screwdriver.fill")
            } description: {
                Text(message)
                Text(
                    "Inject GOTSYNC_RELAY_URL and GOTSYNC_MAILBOX_URL with secure production endpoints."
                )
            }
            .padding(24)
            .navigationTitle(RelayTheme.displayName)
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(RelayTheme.accent)
    }
}

private enum RelaySheet: String, Identifiable {
    case join
    case settings

    var id: String { rawValue }
}

#if DEBUG
#Preview("Content · root") {
    ContentView()
}

#Preview("Content · missing config") {
    SyncConfigurationFailureView(
        message: "This build is missing the AccountlessSyncURL sync endpoint."
    )
    .preferredColorScheme(.dark)
}
#endif
