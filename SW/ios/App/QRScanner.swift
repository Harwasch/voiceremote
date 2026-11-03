import SwiftUI
@preconcurrency import AVFoundation
import UIKit

struct QRScanner: UIViewControllerRepresentable {
    let completion: @MainActor (String?) -> Void
    func makeUIViewController(context: Context) -> ScannerController { ScannerController(completion: completion) }
    func updateUIViewController(_ controller: ScannerController, context: Context) {}
    static func dismantleUIViewController(_ controller: ScannerController, coordinator: ()) { controller.stop() }
}
@MainActor final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private var layer: AVCaptureVideoPreviewLayer?
    private let completion: @MainActor (String?) -> Void
    private var finished = false
    private let queue = DispatchQueue(label: "VoiceRemote.QR")
    init(completion: @escaping @MainActor (String?) -> Void) { self.completion = completion; super.init(nibName: nil, bundle: nil) }
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
            guard await AVCaptureDevice.requestAccess(for: .video), !finished,
                  let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device) else { finish(nil); return }
            session.beginConfiguration()
            guard session.canAddInput(input) else { session.commitConfiguration(); finish(nil); return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { session.commitConfiguration(); finish(nil); return }
            session.addOutput(output); output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
            session.commitConfiguration()
            let layer = AVCaptureVideoPreviewLayer(session: session); layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds; view.layer.insertSublayer(layer, at: 0); self.layer = layer
            let session = self.session
            queue.async { session.startRunning() }
        }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); layer?.frame = view.bounds }
    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        let text = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }.first
        Task { @MainActor [weak self] in if let text { self?.finish(text) } }
    }
    @objc private func cancelScan() { finish(nil) }
    private func finish(_ value: String?) { guard !finished else { return }; finished = true; stop(); completion(value) }
    func stop() { let session = self.session; queue.async { session.stopRunning() } }
}
