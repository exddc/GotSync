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
                } else if let phrase = model.invitationPhrase,
                          let invitationURL = model.invitationURL
                {
                    // Founding invite or any-member group invite.
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
                        joinAction: { presentedSheet = .join }
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
                ? "Keep tasks · reset link?"
                : "Unlink this iPhone?",
            isPresented: $isUnlinkConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(
                model.pairingRecoveryResetRequired
                    ? "Keep Tasks · Reset Link"
                    : "Unlink and Keep Tasks"
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
                    ? "Tasks stay on this iPhone. Unfinished pairing recovery is cleared so you can create Private Sync again. Erase is not required."
                    : ProductSyncPolicy.leaveSyncDetail
            )
        }
        .onOpenURL { url in
            #if DEBUG
            if url.scheme?.lowercased() == "gotdone",
               url.host?.lowercased() == "debug"
            {
                switch url.path.lowercased() {
                case "/create", "create":
                    model.createPrivateSync()
                    return
                case "/invite", "invite":
                    model.inviteToGroup()
                    return
                case "/approve", "approve":
                    model.approveSafetyCode()
                    return
                case "/erase", "erase":
                    model.eraseLocalProofOfConcept()
                    return
                default:
                    break
                }
            }
            #endif
            model.joinPrivateSync(url: url)
        }
        .onAppear {
            #if DEBUG
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if GotDoneDebugLaunch.shouldErase {
                    model.eraseLocalProofOfConcept()
                }
                if let joinURL = GotDoneDebugLaunch.joinURL {
                    model.joinPrivateSync(url: joinURL)
                }
                if GotDoneDebugLaunch.shouldCreateInvite {
                    model.createPrivateSync()
                }
                if GotDoneDebugLaunch.shouldInviteToGroup {
                    model.inviteToGroup()
                }
                if GotDoneDebugLaunch.shouldApproveSafety {
                    model.approveSafetyCode()
                }
                if GotDoneDebugLaunch.shouldSeedGroupUI {
                    model.seedGroupUIForDebug(memberCount: 3)
                }
                if GotDoneDebugLaunch.shouldOpenGroupInvite {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        model.inviteToGroup()
                    }
                }
            }
            if GotDoneDebugLaunch.shouldAutoApproveSafety {
                // Poll briefly for host safety-code confirmation during multi-sim demos.
                Task { @MainActor in
                    for _ in 0..<80 {
                        if model.isHostApprovalPending {
                            model.approveSafetyCode()
                            return
                        }
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                }
            }
            #endif
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
