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
                        eyebrow: "Second iPhone",
                        title: "Join private sync",
                        detail: "Use the invitation shown on the main iPhone. No task data is sent until the main iPhone approves the matching safety code.",
                        symbol: "link.badge.plus"
                    )

                    if model.hasLocalReplicaHistory {
                        Label(
                            "Your local tasks stay on this iPhone during setup. If the task lists differ, Got Done asks how to combine them before the link finishes.",
                            systemImage: "iphone.and.arrow.forward"
                        )
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .relayCard()
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

                    PrivacyDisclosureView(compact: true)
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
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
                .font(.headline)

            TextEditor(text: $phrase)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($phraseIsFocused)
                .frame(minHeight: 132)
                .padding(10)
                .scrollContentBackground(.hidden)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(RelayTheme.field)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(RelayTheme.border, lineWidth: 1)
                }
                .accessibilityLabel("Invitation phrase")
                .accessibilityHint("Enter all seventeen words from the main iPhone.")
                .accessibilityIdentifier("join-phrase-field")

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let phraseValidationMessage {
                Label(
                    phraseValidationMessage,
                    systemImage: "exclamationmark.circle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("\(wordCount) of 17 words")
                    .font(.caption)
                    .foregroundStyle(wordCount == 17 ? RelayTheme.success : .secondary)
            }

            Button {
                joinWithPhrase()
            } label: {
                Label("Continue", systemImage: "arrow.right")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(validatedInvitation == nil)
            .accessibilityIdentifier("join-submit")
        }
        .relayCard()
    }

    private var cameraEntry: some View {
        VStack(spacing: 12) {
            QRScannerView(
                onPayload: { payload in
                    guard
                        let url = URL(string: payload),
                        (try? Invitation.from(url: url)) != nil
                    else {
                        validationMessage = "That QR code is not a Got Done invitation."
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
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.75), lineWidth: 2)
                    .padding(56)
                    .accessibilityHidden(true)
            }

            Text("Point the camera at the QR code on the main iPhone.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if cameraAccessDenied {
                HStack {
                    Button("Open Settings") {
                        guard let url = URL(
                            string: UIApplication.openSettingsURLString
                        ) else {
                            return
                        }
                        UIApplication.shared.open(url)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Enter Phrase") {
                        inputMode = .phrase
                        phraseIsFocused = true
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
            }

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
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
