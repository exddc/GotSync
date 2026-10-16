import AVFoundation
import GotSync
import SwiftUI

struct JoinSyncSheet: View {
    @ObservedObject var model: SyncAppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var scannerID = UUID()
    @Environment(\.dismiss) private var dismiss
    @State private var invitation = ""
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Scan the invitation on the first phone. You will then show a response code for it to scan.")
                        .foregroundStyle(RelayTheme.inkMuted)
                    if model.hasLocalReplicaHistory {
                        Text("Your local tasks stay on this phone. You will review how to combine the lists before linking finishes.")
                            .font(.footnote)
                            .foregroundStyle(RelayTheme.inkMuted)
                    }
                    QRScannerView(onPayload: { payload in join(payload) }, onCameraAccessDenied: {
                        message = "Allow camera access in Settings, or paste the invitation link below."
                    })
                    .id(scannerID)
                    .frame(height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    TextField("Or paste the invitation link", text: $invitation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    Button("Continue") { _ = join(invitation) }
                        .pocPrimaryButtonStyle()
                        .disabled(invitation.isEmpty)
                    if let message { Text(message).foregroundStyle(RelayTheme.danger) }
                }
                .padding(22)
            }
            .background(SoftFieldBackground())
            .navigationTitle("Join link")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
                scannerID = UUID(); message = nil
            }
        }
    }

    private func join(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let qr = try? MLSQR.from(url: url, scheme: DemoEndpoints.invitationURLScheme), !qr.isResponse else {
            message = "Scan an Accountless Sync invitation from the first phone."
            return false
        }
        model.joinPrivateSync(url: url)
        dismiss()
        return true
    }
}
