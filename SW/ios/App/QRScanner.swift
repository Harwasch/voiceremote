import SwiftUI
@preconcurrency import AVFoundation
import UIKit

struct QRScanner: UIViewControllerRepresentable {
    let completion: @MainActor @Sendable (String?) -> Void
    func makeUIViewController(context: Context) -> ScannerController { ScannerController(completion: completion) }
    func updateUIViewController(_ controller: ScannerController, context: Context) {}
    static func dismantleUIViewController(_ controller: ScannerController, coordinator: ()) { controller.stop() }
}
@MainActor final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let capture = ScannerSession()
    private var layer: AVCaptureVideoPreviewLayer?
    private let completion: @MainActor @Sendable (String?) -> Void
    private var finished = false
    init(completion: @escaping @MainActor @Sendable (String?) -> Void) { self.completion = completion; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let cancel = UIButton(type: .system); cancel.setTitle("Cancel scan", for: .normal)
        cancel.addTarget(self, action: #selector(cancelScan), for: .touchUpInside)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cancel)
        NSLayoutConstraint.activate([cancel.centerXAnchor.constraint(equalTo: view.centerXAnchor), cancel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24)])
        Task {
            guard await AVCaptureDevice.requestAccess(for: .video), !finished else { finish(nil); return }
            let layer = capture.makePreviewLayer(); layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds; view.layer.insertSublayer(layer, at: 0); self.layer = layer
            capture.start(delegate: self) { [weak self] success in if !success { self?.finish(nil) } }
        }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); layer?.frame = view.bounds }
    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        let text = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }.first
        Task { @MainActor [weak self] in if let text { self?.finish(text) } }
    }
    @objc private func cancelScan() { finish(nil) }
    private func finish(_ value: String?) { guard !finished else { return }; finished = true; stop(); completion(value) }
    func stop() { finished = true; capture.stop() }
}

/// All session configuration/start/stop is confined to queue. The only shared
/// SDK use is attaching its preview layer on main, as required by AVFoundation.
/// No AVCaptureSession is captured by a MainActor-to-dispatch closure.
private final class ScannerSession: @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "VoiceRemote.QR")
    private var stopped = false // queue only; cancellation cannot race configuration

    @MainActor func makePreviewLayer() -> AVCaptureVideoPreviewLayer { AVCaptureVideoPreviewLayer(session: session) }

    func start(delegate: ScannerController, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        queue.async { @Sendable [self] in
            guard !stopped else { return }
            let success = configure(delegate: delegate)
            if success { session.startRunning() }
            Task { @MainActor in completion(success) }
        }
    }
    private func configure(delegate: ScannerController) -> Bool {
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration(); defer { session.commitConfiguration() }
        guard session.canAddInput(input) else { return false }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return false }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(delegate, queue: .main)
        output.metadataObjectTypes = [.qr]
        return true
    }
    func stop() { queue.async { @Sendable [self] in stopped = true; session.stopRunning() } }
}
