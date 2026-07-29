import SwiftUI

@MainActor
struct ContentView: View {
    private let configuration: SyncEndpointConfiguration?
    private let configurationError: String?

    init(bundle: Bundle = .main) {
        do {
            configuration = try SyncEndpointConfiguration.load(bundle: bundle)
            configurationError = nil
        } catch {
            configuration = nil
            configurationError = Self.displayMessage(for: error)
        }
    }

    var body: some View {
        if let configuration {
            SyncRootView(configuration: configuration)
        } else {
            SyncConfigurationFailureView(
                message: configurationError
                    ?? "This build is missing secure sync endpoints."
            )
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
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var model: SyncAppModel
    @State private var presentedSheet: RelaySheet?
    @State private var isResetConfirmationPresented = false
    @State private var isUnlinkConfirmationPresented = false

    init(configuration: SyncEndpointConfiguration) {
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
                } else if model.isPaired {
                    TaskDashboardView(
                        model: model,
                        isResetConfirmationPresented: $isResetConfirmationPresented,
                        isUnlinkConfirmationPresented: $isUnlinkConfirmationPresented,
                        joinAction: { presentedSheet = .join }
                    )
                } else if let phrase = model.invitationPhrase,
                          let invitationURL = model.invitationURL
                {
                    PairingInvitationView(
                        model: model,
                        phrase: phrase,
                        invitationURL: invitationURL
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
                        joinAction: { presentedSheet = .join }
                    )
                } else {
                    WelcomeView(
                        model: model,
                        joinAction: { presentedSheet = .join },
                        eraseAction: {
                            isResetConfirmationPresented = true
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RelayTheme.background.ignoresSafeArea())
            .animation(
                reduceMotion ? nil : .smooth(duration: 0.28),
                value: model.phase
            )
        }
        .tint(RelayTheme.accent)
        .sheet(item: $presentedSheet) { destination in
            switch destination {
            case .join:
                JoinSyncSheet(model: model)
            }
        }
        .confirmationDialog(
            "Erase this proof of concept?",
            isPresented: $isResetConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Erase Link and Local Tasks", role: .destructive) {
                model.eraseLocalProofOfConcept()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This removes the pairing keys and every task in this sample app from this iPhone. The other iPhone is not erased."
            )
        }
        .confirmationDialog(
            model.pairingRecoveryResetRequired
                ? "Reset Private Sync?"
                : "Unlink this iPhone?",
            isPresented: $isUnlinkConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(
                model.pairingRecoveryResetRequired
                    ? "Keep Tasks and Reset Sync"
                    : "Unlink and Keep Tasks"
            ) {
                model.unlinkAndKeepTasks()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                model.pairingRecoveryResetRequired
                    ? "Tasks stay on this iPhone. Unfinished recovery proofs are removed, and a phone from the old link may also need its link reset."
                    : "Tasks stay on this iPhone. It stops using the old link, so you can create a new private sync for a replacement phone."
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
}

private struct SyncConfigurationFailureView: View {
    let message: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Sync build needs configuration", systemImage: "wrench.and.screwdriver.fill")
            } description: {
                Text(message)
                Text(
                    "Inject GOTDONE_RELAY_URL and GOTDONE_MAILBOX_URL with secure production endpoints."
                )
            }
            .padding(24)
            .navigationTitle("Got Done")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(RelayTheme.accent)
    }
}

private enum RelaySheet: String, Identifiable {
    case join

    var id: String { rawValue }
}
