import GotSync
@preconcurrency import AVFoundation
import SwiftUI
import UIKit

struct QRScannerView: UIViewControllerRepresentable {
    let onPayload: @MainActor (String) -> Bool
    let onCameraAccessDenied: @MainActor () -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        QRScannerViewController(
            onPayload: onPayload,
            onCameraAccessDenied: onCameraAccessDenied
        )
    }

    func updateUIViewController(
        _ uiViewController: QRScannerViewController,
        context: Context
    ) {}
}

#if DEBUG
#Preview("QR scanner") {
    QRScannerView(
        onPayload: { _ in true },
        onCameraAccessDenied: {}
    )
    .ignoresSafeArea()
    .preferredColorScheme(.dark)
}
#endif

@MainActor
final class QRScannerViewController: UIViewController {
    private let captureWorker = QRScannerCaptureWorker()
    private let onPayload: @MainActor (String) -> Bool
    private let onCameraAccessDenied: @MainActor () -> Void
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didScan = false
    private var didDisappear = false
    private lazy var metadataDelegate = QRScannerMetadataDelegate {
        [weak self] payload in
        self?.handlePayload(payload)
    }

    init(
        onPayload: @escaping @MainActor (String) -> Bool,
        onCameraAccessDenied: @escaping @MainActor () -> Void
    ) {
        self.onPayload = onPayload
        self.onCameraAccessDenied = onCameraAccessDenied
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        Task {
            let isAllowed = await AVCaptureDevice.requestAccess(for: .video)
            if isAllowed {
                configureSession()
            } else {
                onCameraAccessDenied()
                showCameraMessage(
                    "Camera access is off. Enable it in Settings or use the phrase."
                )
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        didDisappear = true
        captureWorker.stop()
    }

    private func configureSession() {
        captureWorker.configureAndStart(delegate: metadataDelegate) {
            [weak self] result in
            guard let self, !didDisappear else {
                return
            }
            switch result {
            case .ready:
                installPreviewLayer()
            case .unavailable(let message):
                showCameraMessage(message)
            }
        }
    }

    private func installPreviewLayer() {
        let previewLayer = AVCaptureVideoPreviewLayer(
            session: captureWorker.captureSession
        )
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.bounds
        view.layer.addSublayer(previewLayer)
        self.previewLayer = previewLayer
    }

    private func handlePayload(_ value: String) {
        guard !didScan, onPayload(value) else {
            return
        }
        didScan = true
        captureWorker.stop()
    }

    private func showCameraMessage(_ message: String) {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = message
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .body)
        label.numberOfLines = 0
        label.textAlignment = .center
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}

private enum QRScannerCaptureResult: Sendable {
    case ready
    case unavailable(String)
}

private final class QRScannerCaptureWorker: @unchecked Sendable {
    let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(
        label: "com.gotdone.relay.qr-scanner"
    )

    func configureAndStart(
        delegate: QRScannerMetadataDelegate,
        completion: @escaping @MainActor @Sendable (QRScannerCaptureResult) -> Void
    ) {
        sessionQueue.async { [self] in
            guard
                let camera = AVCaptureDevice.default(for: .video),
                let input = try? AVCaptureDeviceInput(device: camera),
                captureSession.canAddInput(input)
            else {
                complete(
                    .unavailable(
                        "The camera is unavailable. Use the phrase instead."
                    ),
                    with: completion
                )
                return
            }

            captureSession.beginConfiguration()
            captureSession.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard captureSession.canAddOutput(output) else {
                captureSession.commitConfiguration()
                complete(
                    .unavailable(
                        "The camera is unavailable. Use the phrase instead."
                    ),
                    with: completion
                )
                return
            }

            captureSession.addOutput(output)
            output.setMetadataObjectsDelegate(delegate, queue: .main)
            output.metadataObjectTypes = [.qr]
            captureSession.commitConfiguration()
            captureSession.startRunning()
            complete(.ready, with: completion)
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            guard captureSession.isRunning else {
                return
            }
            captureSession.stopRunning()
        }
    }

    private func complete(
        _ result: QRScannerCaptureResult,
        with completion: @escaping @MainActor @Sendable (
            QRScannerCaptureResult
        ) -> Void
    ) {
        Task { @MainActor in
            completion(result)
        }
    }
}

private final class QRScannerMetadataDelegate: NSObject,
    AVCaptureMetadataOutputObjectsDelegate,
    @unchecked Sendable
{
    private let onPayload: @MainActor @Sendable (String) -> Void

    init(onPayload: @escaping @MainActor @Sendable (String) -> Void) {
        self.onPayload = onPayload
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard
            let readable = metadataObjects.first
                as? AVMetadataMachineReadableCodeObject,
            let value = readable.stringValue
        else {
            return
        }
        Task { @MainActor in
            onPayload(value)
        }
    }
}
