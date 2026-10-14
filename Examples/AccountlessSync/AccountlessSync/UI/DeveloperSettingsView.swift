import GotSync
import SwiftUI

struct DeveloperSettingsView: View {
    let currentRelayURL: URL
    let onRelayURLApplied: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var relayURLText: String
    @State private var validationMessage: String?
    @State private var connectionStatus: ConnectionStatus = .unknown
    @State private var isCheckingConnection = false

    enum ConnectionStatus: Equatable {
        case unknown
        case checking
        case connected
        case disconnected

        var label: String {
            switch self {
            case .unknown:
                "Not checked"
            case .checking:
                "Checking…"
            case .connected:
                "Connected"
            case .disconnected:
                "Disconnected"
            }
        }

        var color: Color {
            switch self {
            case .unknown, .checking:
                RelayTheme.inkMuted
            case .connected:
                RelayTheme.live
            case .disconnected:
                RelayTheme.danger
            }
        }
    }

    init(
        currentRelayURL: URL,
        onRelayURLApplied: @escaping (URL) -> Void
    ) {
        self.currentRelayURL = currentRelayURL
        self.onRelayURLApplied = onRelayURLApplied
        _relayURLText = State(
            initialValue: DeveloperEndpointPreferences.relayURLOverrideString
                ?? currentRelayURL.absoluteString
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        developerDetail
                    } label: {
                        Label("Developer", systemImage: "hammer")
                    }
                } footer: {
                    Text("Advanced options for local demos and debugging.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(SoftFieldBackground())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(RelayTheme.accent)
    }

    private var developerDetail: some View {
        Form {
            Section {
                TextField(
                    "ws://host:port/v1",
                    text: $relayURLText,
                    axis: .vertical
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1...3)
                .accessibilityIdentifier("developer-relay-url-field")

                Button("Save relay URL") {
                    saveRelayURL()
                }
                .disabled(isCheckingConnection)

                if DeveloperEndpointPreferences.relayURLOverrideString != nil {
                    Button("Reset to build default", role: .destructive) {
                        resetRelayURL()
                    }
                }
            } header: {
                Text("Relay URL")
            } footer: {
                Text(
                    "Must be ws:// or wss:// ending in /v1. Applies on save and restarts the local sync session."
                )
            }

            Section {
                Button {
                    Task { await checkConnection() }
                } label: {
                    if isCheckingConnection {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking…")
                        }
                    } else {
                        Text("Check connection")
                    }
                }
                .disabled(isCheckingConnection)
                .accessibilityIdentifier("developer-check-connection")

                LabeledContent("Status") {
                    Text(connectionStatus.label)
                        .foregroundStyle(connectionStatus.color)
                        .fontWeight(.medium)
                        .accessibilityIdentifier("developer-connection-status")
                }
            } header: {
                Text("Connection")
            } footer: {
                Text("Opens a short WebSocket to the relay URL above.")
            }

            if let validationMessage {
                Section {
                    Text(validationMessage)
                        .font(.footnote)
                        .foregroundStyle(RelayTheme.danger)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(SoftFieldBackground())
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func saveRelayURL() {
        validationMessage = nil
        connectionStatus = .unknown
        let trimmed = relayURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            validationMessage = "Enter a valid relay URL."
            return
        }
        do {
            try SyncEndpointConfiguration.validateRelayURL(
                url,
                policy: DemoEndpoints.policy
            )
        } catch {
            validationMessage = (error as? LocalizedError)?.errorDescription
                ?? "Invalid relay URL."
            return
        }
        DeveloperEndpointPreferences.relayURLOverrideString = trimmed
        relayURLText = trimmed
        onRelayURLApplied(url)
        validationMessage = nil
    }

    private func resetRelayURL() {
        validationMessage = nil
        connectionStatus = .unknown
        DeveloperEndpointPreferences.clearRelayURLOverride()
        do {
            let configuration = try SyncEndpointConfiguration.load()
            relayURLText = configuration.relayURL.absoluteString
            onRelayURLApplied(configuration.relayURL)
        } catch {
            relayURLText = DemoEndpoints.relayURL.absoluteString
            onRelayURLApplied(DemoEndpoints.relayURL)
        }
    }

    @MainActor
    private func checkConnection() async {
        validationMessage = nil
        let trimmed = relayURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            connectionStatus = .disconnected
            validationMessage = "Enter a valid relay URL."
            return
        }
        do {
            try SyncEndpointConfiguration.validateRelayURL(
                url,
                policy: DemoEndpoints.policy
            )
        } catch {
            connectionStatus = .disconnected
            validationMessage = (error as? LocalizedError)?.errorDescription
                ?? "Invalid relay URL."
            return
        }

        isCheckingConnection = true
        connectionStatus = .checking
        let reachable = await RelaySocket.probeReachability(url: url, policy: DemoEndpoints.policy)
        connectionStatus = reachable ? .connected : .disconnected
        isCheckingConnection = false
    }
}

#if DEBUG
#Preview("Developer settings") {
    DeveloperSettingsView(
        currentRelayURL: DemoEndpoints.relayURL,
        onRelayURLApplied: { _ in }
    )
}
#endif
