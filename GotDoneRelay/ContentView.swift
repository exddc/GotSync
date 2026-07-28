import SwiftUI

@MainActor
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = SyncAppModel()
    @State private var presentedSheet: RelaySheet?
    @State private var isResetConfirmationPresented = false

    var body: some View {
        NavigationStack {
            Group {
                if model.isPaired {
                    TaskDashboardView(
                        model: model,
                        isResetConfirmationPresented: $isResetConfirmationPresented
                    )
                } else if let safetyCode = model.safetyCode {
                    SafetyCodeView(model: model, code: safetyCode)
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
                {
                    PairingProgressView(model: model)
                } else {
                    WelcomeView(
                        model: model,
                        joinAction: { presentedSheet = .join }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RelayTheme.background.ignoresSafeArea())
            .animation(.smooth(duration: 0.28), value: model.phase)
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

private enum RelaySheet: String, Identifiable {
    case join

    var id: String { rawValue }
}
