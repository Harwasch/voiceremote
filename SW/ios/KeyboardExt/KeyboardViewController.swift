import UIKit
import CoreFoundation
import KeyboardBridge

final class KeyboardViewController: UIInputViewController, TextInserter {
    private let statusLine = UILabel()
    private var reader: QueueReader?
    private var observing = false
    private var active = false
    private var poll: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        statusLine.text = "Start dictation in Voice Remote · Destination: current field"
        statusLine.font = .preferredFont(forTextStyle: .footnote)
        statusLine.numberOfLines = 0
        let globe = UIButton(type: .system)
        globe.setTitle("🌐", for: .normal)
        globe.accessibilityLabel = "Switch keyboard"
        globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        let space = UIButton(type: .system)
        space.setTitle("Space", for: .normal)
        space.addTarget(self, action: #selector(insertSpace), for: .touchUpInside)
        let delete = UIButton(type: .system)
        delete.setTitle("Delete", for: .normal)
        delete.addTarget(self, action: #selector(deleteCharacter), for: .touchUpInside)
        let keys = UIStackView(arrangedSubviews: [globe, space, delete])
        keys.distribution = .fillEqually
        let stack = UIStackView(arrangedSubviews: [statusLine, keys])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            keys.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])
        // App Group prefix follows the existing bundle/entitlement configuration.
        if let bundle = Bundle.main.bundleIdentifier, bundle.hasSuffix(".keyboard"),
           let shared = FileManager.default.containerURL(
               forSecurityApplicationGroupIdentifier: "group." + String(bundle.dropLast(".keyboard".count))),
           let local = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            reader = QueueReader(sharedDirectory: shared,
                                 localDirectory: local.appendingPathComponent("KeyboardBridge"))
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        active = true
        if !observing {
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(), { _, observer, _, _, _ in
                    guard let observer else { return }
                    // Darwin callback payloads carry no text. UIKit work always runs on main.
                    let controller = Unmanaged<KeyboardViewController>.fromOpaque(observer).takeUnretainedValue()
                    Task { @MainActor [weak controller] in controller?.refresh() }
                }, BridgePolicy.notificationName as CFString, nil, .deliverImmediately)
            observing = true
        }
        // Notifications are advisory and can be coalesced/lost while suspended.
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refresh()
    }

    override func viewWillDisappear(_ animated: Bool) {
        active = false
        poll?.invalidate()
        poll = nil
        if observing {
            CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(),
                CFNotificationName(rawValue: BridgePolicy.notificationName as CFString), nil)
            observing = false
        }
        super.viewWillDisappear(animated)
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque())
    }

    private func refresh() {
        guard active else { return }
        guard let reader else {
            statusLine.text = "Bridge unavailable · Use copy/share in Voice Remote"
            return
        }
        do {
            let status = try reader.status()
            statusLine.text = "\(status.listening ? "Listening in main app" : "Ready") · Destination: current field"
            try reader.drain(into: self)
        } catch {
            statusLine.text = "Insertion paused · Use copy/share in Voice Remote"
        }
    }

    func insertText(_ text: String) throws {
        try BridgePolicy.validate(text)
        textDocumentProxy.insertText(text)
    }
    @objc private func insertSpace() { try? insertText(" ") }
    @objc private func deleteCharacter() { textDocumentProxy.deleteBackward() }
}
