@preconcurrency import AVFoundation
import SwiftUI
import UIKit

struct QRScannerView: UIViewControllerRepresentable {
    let onPayload: @MainActor (String) -> Bool

    func makeUIViewController(context: Context) -> QRScannerViewController {
        QRScannerViewController(onPayload: onPayload)
    }

    func updateUIViewController(
        _ uiViewController: QRScannerViewController,
        context: Context
    ) {}
}

@MainActor
final class QRScannerViewController: UIViewController,
    @preconcurrency AVCaptureMetadataOutputObjectsDelegate
{
    private let captureSession = AVCaptureSession()
    private let onPayload: @MainActor (String) -> Bool
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didScan = false

    init(onPayload: @escaping @MainActor (String) -> Bool) {
        self.onPayload = onPayload
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
        captureSession.stopRunning()
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard
            !didScan,
            let readable = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
            let value = readable.stringValue
        else {
            return
        }
        guard onPayload(value) else {
            return
        }
        didScan = true
        captureSession.stopRunning()
    }

    private func configureSession() {
        guard
            let camera = AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: camera),
            captureSession.canAddInput(input)
        else {
            showCameraMessage("The camera is unavailable. Use the phrase instead.")
            return
        }

        captureSession.beginConfiguration()
        captureSession.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(output) else {
            captureSession.commitConfiguration()
            showCameraMessage("The camera is unavailable. Use the phrase instead.")
            return
        }
        captureSession.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        captureSession.commitConfiguration()

        let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.bounds
        view.layer.addSublayer(previewLayer)
        self.previewLayer = previewLayer
        captureSession.startRunning()
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
