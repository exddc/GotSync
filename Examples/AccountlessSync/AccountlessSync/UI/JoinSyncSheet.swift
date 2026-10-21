import GotSync
import AVFoundation
import SwiftUI

struct JoinSyncSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var model: SyncAppModel
    @State private var phrase = ""
    @State private var inputMode: JoinInputMode
    @State private var validationMessage: String?
    @State private var cameraAccessDenied = false
    @State private var scannerID = UUID()
    @FocusState private var phraseIsFocused: Bool

    init(model: SyncAppModel) {
        self.model = model
        _inputMode = State(
            initialValue: AVCaptureDevice.default(for: .video) == nil
                ? .phrase
                : .camera
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PairingHeaderView(
                        title: "Scan to link",
                        detail: "Scan the code on the other phone. Use the phrase only if the camera is unavailable. Nothing is shared until codes match and are approved.",
                        symbol: "viewfinder"
                    )

                    if model.hasLocalReplicaHistory {
                        Label(
                            "Local tasks stay on this phone. After linking, they are added to the shared list.",
                            systemImage: "iphone.and.arrow.forward"
                        )
                        .font(.footnote)
                        .foregroundStyle(RelayTheme.inkMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .relayCard(padding: 14)
                        .accessibilityElement(children: .combine)
                    }

                    if cameraIsAvailable {
                        Picker("Invitation method", selection: $inputMode) {
                            ForEach(JoinInputMode.allCases) { mode in
                                Label(mode.title, systemImage: mode.symbol)
                                    .tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    switch inputMode {
                    case .phrase:
                        phraseEntry
                    case .camera:
                        cameraEntry
                    }
                }
                .padding(22)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(SoftFieldBackground())
            .navigationTitle("Join")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
        .onChange(of: inputMode) {
            validationMessage = nil
        }
        .onChange(of: phrase) {
            validationMessage = nil
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, inputMode == .camera else {
                return
            }
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                cameraAccessDenied = false
                scannerID = UUID()
            case .denied, .restricted:
                cameraAccessDenied = true
            case .notDetermined:
                break
            @unknown default:
                cameraAccessDenied = true
            }
        }
    }

    private var phraseEntry: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("17-word phrase")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(RelayTheme.ink)

            TextEditor(text: $phrase)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($phraseIsFocused)
                .frame(minHeight: 132)
                .padding(12)
                .scrollContentBackground(.hidden)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(RelayTheme.field)
                )
                .accessibilityLabel("Invitation phrase")
                .accessibilityHint("Enter all seventeen words from the other phone.")
                .accessibilityIdentifier("join-phrase-field")

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(RelayTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let phraseValidationMessage {
                Label(
                    phraseValidationMessage,
                    systemImage: "exclamationmark.circle.fill"
                )
                .font(.footnote)
                .foregroundStyle(RelayTheme.danger)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("\(wordCount) of 17 words")
                    .font(.caption)
                    .foregroundStyle(wordCount == 17 ? RelayTheme.accent : RelayTheme.inkMuted)
            }

            Button {
                joinWithPhrase()
            } label: {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .pocPrimaryButtonStyle()
            .controlSize(.large)
            .disabled(validatedInvitation == nil)
            .accessibilityIdentifier("join-submit")
        }
        .relayCard(padding: 16)
    }

    private var cameraEntry: some View {
        VStack(spacing: 12) {
            QRScannerView(
                onPayload: { payload in
                    guard
                        let url = URL(string: payload),
                        (try? Invitation.from(url: url, scheme: DemoEndpoints.invitationURLScheme)) != nil
                    else {
                        validationMessage = "That QR code is not an Accountless Sync invitation."
                        return false
                    }
                    validationMessage = nil
                    model.joinPrivateSync(url: url)
                    if model.phase == .failed {
                        validationMessage = model.errorMessage
                        return false
                    } else {
                        dismiss()
                        return true
                    }
                },
                onCameraAccessDenied: {
                    cameraAccessDenied = true
                }
            )
            .id(scannerID)
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(RelayTheme.qrPlate.opacity(0.85), lineWidth: 1.5)
                    .padding(56)
                    .accessibilityHidden(true)
            }

            Text("Point the camera at the QR code on the other phone.")
                .font(.footnote)
                .foregroundStyle(RelayTheme.inkMuted)
                .multilineTextAlignment(.center)

            if cameraAccessDenied {
                VStack(alignment: .leading, spacing: 10) {
                    Label(
                        "Camera is off. Join with the 17-word phrase, or enable camera in Settings.",
                        systemImage: "camera.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(RelayTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Button("Open Settings") {
                            guard let url = URL(
                                string: UIApplication.openSettingsURLString
                            ) else {
                                return
                            }
                            UIApplication.shared.open(url)
                        }
                        .pocPrimaryButtonStyle()

                        Button("Enter phrase") {
                            inputMode = .phrase
                            phraseIsFocused = true
                        }
                        .pocSecondaryButtonStyle()
                    }
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(RelayTheme.danger)
            }
        }
    }

    private var wordCount: Int {
        phrase.split(whereSeparator: \.isWhitespace).count
    }

    private var cameraIsAvailable: Bool {
        AVCaptureDevice.default(for: .video) != nil
    }

    private var validatedInvitation: Invitation? {
        guard wordCount == 17 else {
            return nil
        }
        return try? Invitation.from(phrase: phrase)
    }

    private var phraseValidationMessage: String? {
        guard wordCount >= 17 else {
            return nil
        }
        guard wordCount == 17 else {
            return "Use exactly 17 words."
        }
        do {
            _ = try Invitation.from(phrase: phrase)
            return nil
        } catch MnemonicError.unknownWord(let word) {
            return "“\(word)” is not in this invitation."
        } catch MnemonicError.invalidChecksum {
            return "The words do not form a valid invitation. Check the last word."
        } catch {
            return "This invitation phrase is invalid."
        }
    }

    private func joinWithPhrase() {
        validationMessage = nil
        guard validatedInvitation != nil else {
            validationMessage = phraseValidationMessage
                ?? "Enter all 17 invitation words."
            return
        }
        model.joinPrivateSync(phrase: phrase)
        if model.phase == .failed {
            validationMessage = model.errorMessage
        } else {
            dismiss()
        }
    }
}

private enum JoinInputMode: String, CaseIterable, Identifiable {
    case camera
    case phrase

    var id: String { rawValue }

    var title: String {
        switch self {
        case .phrase:
            "Phrase"
        case .camera:
            "Scan"
        }
    }

    var symbol: String {
        switch self {
        case .phrase:
            "text.word.spacing"
        case .camera:
            "qrcode.viewfinder"
        }
    }
}

#if DEBUG
#Preview("Join sync") {
    @Previewable @StateObject var model = PreviewSupport.model()
    JoinSyncSheet(model: model)
        .preferredColorScheme(.dark)
}
#endif

