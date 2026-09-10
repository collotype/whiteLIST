import UIKit
import Foundation
import Darwin

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: ViewController())
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

final class ViewController: UIViewController {
    private let defaults = UserDefaults.standard
    private var outputPipe: Pipe?
    private var statusTimer: Timer?

    private let transportControl: UISegmentedControl = {
        let c = UISegmentedControl(items: ["Yandex", "MAX"])
        c.translatesAutoresizingMaskIntoConstraints = false
        c.selectedSegmentIndex = 0
        return c
    }()

    private let urlField = ViewController.makeField(
        placeholder: "Yandex Docs URL",
        keyboard: .URL,
        secure: false
    )

    private let maxTokenField = ViewController.makeField(
        placeholder: "MAX token",
        keyboard: .default,
        secure: true
    )

    private let maxUIDField = ViewController.makeField(
        placeholder: "MAX UID",
        keyboard: .numberPad,
        secure: false
    )

    private let connectButton: UIButton = {
        let b = UIButton(type: .system)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.configuration = .filled()
        b.setTitle("Connect", for: .normal)
        return b
    }()

    private let disconnectButton: UIButton = {
        let b = UIButton(type: .system)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.configuration = .bordered()
        b.setTitle("Disconnect", for: .normal)
        b.isEnabled = false
        return b
    }()

    private let testButton: UIButton = {
        let b = UIButton(type: .system)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.configuration = .bordered()
        b.setTitle("Test tunnel", for: .normal)
        b.isEnabled = false
        return b
    }()

    private let statusLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.numberOfLines = 0
        l.font = .systemFont(ofSize: 15, weight: .semibold)
        l.text = "● Stopped"
        return l
    }()

    private let statsLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.numberOfLines = 0
        l.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        l.text = "SOCKS5: 127.0.0.1:1080"
        return l
    }()

    private let noteLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.numberOfLines = 0
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabel
        l.text = "This build runs the original OpenFlux transport and a local SOCKS5 proxy. It is not a system-wide iOS VPN. Keep the app open while testing."
        return l
    }()

    private let logView: UITextView = {
        let v = UITextView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isEditable = false
        v.isSelectable = true
        v.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        v.layer.borderWidth = 0.5
        v.layer.cornerRadius = 8
        return v
    }()

    private let clearLogButton: UIButton = {
        let b = UIButton(type: .system)
        b.setTitle("Clear log", for: .normal)
        return b
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "OpenFlux"
        view.backgroundColor = .systemBackground

        installOutputCapture()
        buildUI()
        loadSettings()
        updateTransportFields()
        startStatusTimer()

        appendLog("[iOS] OpenFlux wrapper ready")
        appendLog("[iOS] SOCKS5 endpoint: 127.0.0.1:1080")
    }

    deinit {
        statusTimer?.invalidate()
        outputPipe?.fileHandleForReading.readabilityHandler = nil
    }

    private static func makeField(
        placeholder: String,
        keyboard: UIKeyboardType,
        secure: Bool
    ) -> UITextField {
        let f = UITextField()
        f.translatesAutoresizingMaskIntoConstraints = false
        f.borderStyle = .roundedRect
        f.placeholder = placeholder
        f.keyboardType = keyboard
        f.autocapitalizationType = .none
        f.autocorrectionType = .no
        f.isSecureTextEntry = secure
        f.clearButtonMode = .whileEditing
        return f
    }

    private func buildUI() {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        let content = UIStackView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.axis = .vertical
        content.spacing = 12
        scroll.addSubview(content)

        let buttons = UIStackView(arrangedSubviews: [connectButton, disconnectButton])
        buttons.axis = .horizontal
        buttons.spacing = 10
        buttons.distribution = .fillEqually

        let logHeader = UIStackView()
        logHeader.axis = .horizontal
        let logTitle = UILabel()
        logTitle.text = "Live log"
        logTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        logHeader.addArrangedSubview(logTitle)
        logHeader.addArrangedSubview(UIView())
        logHeader.addArrangedSubview(clearLogButton)

        content.addArrangedSubview(transportControl)
        content.addArrangedSubview(urlField)
        content.addArrangedSubview(maxTokenField)
        content.addArrangedSubview(maxUIDField)
        content.addArrangedSubview(buttons)
        content.addArrangedSubview(testButton)
        content.addArrangedSubview(statusLabel)
        content.addArrangedSubview(statsLabel)
        content.addArrangedSubview(noteLabel)
        content.addArrangedSubview(logHeader)
        content.addArrangedSubview(logView)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32),

            logView.heightAnchor.constraint(equalToConstant: 320)
        ])

        transportControl.addTarget(self, action: #selector(transportChanged), for: .valueChanged)
        connectButton.addTarget(self, action: #selector(connectTapped), for: .touchUpInside)
        disconnectButton.addTarget(self, action: #selector(disconnectTapped), for: .touchUpInside)
        testButton.addTarget(self, action: #selector(testTapped), for: .touchUpInside)
        clearLogButton.addTarget(self, action: #selector(clearLogTapped), for: .touchUpInside)
    }

    private func installOutputCapture() {
        let pipe = Pipe()
        outputPipe = pipe
        let fd = pipe.fileHandleForWriting.fileDescriptor

        dup2(fd, STDOUT_FILENO)
        dup2(fd, STDERR_FILENO)

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                self?.appendLog(text, timestamp: false)
            }
        }
    }

    @objc private func transportChanged() {
        updateTransportFields()
        saveSettings()
    }

    private func updateTransportFields() {
        let isYandex = transportControl.selectedSegmentIndex == 0
        urlField.isHidden = !isYandex
        maxTokenField.isHidden = isYandex
        maxUIDField.isHidden = isYandex
    }

    @objc private func connectTapped() {
        view.endEditing(true)
        saveSettings()

        connectButton.isEnabled = false
        transportControl.isEnabled = false
        urlField.isEnabled = false
        maxTokenField.isEnabled = false
        maxUIDField.isEnabled = false

        statusLabel.text = "● Starting…"
        appendLog("[iOS] ===== CONNECT =====")

        let isYandex = transportControl.selectedSegmentIndex == 0

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result: Int32

            if isYandex {
                let url = self.urlField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if url.isEmpty {
                    DispatchQueue.main.async {
                        self.finishStartFailure("Enter Yandex Docs URL")
                    }
                    return
                }
                result = url.withCString { ptr in
                    OFStartYandex(UnsafeMutablePointer(mutating: ptr))
                }
            } else {
                let token = self.maxTokenField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let uidText = self.maxUIDField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !token.isEmpty, let uid = Int64(uidText), uid > 0 else {
                    DispatchQueue.main.async {
                        self.finishStartFailure("Enter MAX token and numeric UID")
                    }
                    return
                }
                result = token.withCString { ptr in
                    OFStartMax(UnsafeMutablePointer(mutating: ptr), uid)
                }
            }

            DispatchQueue.main.async {
                if result == 0 {
                    self.appendLog("[iOS] Start accepted; waiting for transport")
                    self.disconnectButton.isEnabled = true
                    self.testButton.isEnabled = true
                } else {
                    self.finishStartFailure("OpenFlux start failed (code \(result))")
                }
            }
        }
    }

    private func finishStartFailure(_ message: String) {
        appendLog("[iOS] ERROR: \(message)")
        statusLabel.text = "● \(message)"
        connectButton.isEnabled = true
        transportControl.isEnabled = true
        urlField.isEnabled = true
        maxTokenField.isEnabled = true
        maxUIDField.isEnabled = true
        disconnectButton.isEnabled = false
        testButton.isEnabled = false
    }

    @objc private func disconnectTapped() {
        disconnectButton.isEnabled = false
        testButton.isEnabled = false
        appendLog("[iOS] ===== DISCONNECT =====")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = OFStop()
            DispatchQueue.main.async {
                guard let self else { return }
                self.connectButton.isEnabled = true
                self.transportControl.isEnabled = true
                self.urlField.isEnabled = true
                self.maxTokenField.isEnabled = true
                self.maxUIDField.isEnabled = true
                self.statusLabel.text = "● Stopped"
            }
        }
    }

    @objc private func testTapped() {
        testButton.isEnabled = false
        appendLog("[iOS] Running tunnel TCP test…")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let ptr = OFTestTunnel() else { return }
            let result = String(cString: ptr)
            OFFreeString(ptr)

            DispatchQueue.main.async {
                guard let self else { return }
                self.appendLog("[TEST] \(result)")
                self.testButton.isEnabled = true

                let alert = UIAlertController(
                    title: result.hasPrefix("OK:") ? "Tunnel works" : "Tunnel test failed",
                    message: result,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                self.present(alert, animated: true)
            }
        }
    }

    @objc private func clearLogTapped() {
        logView.text = ""
        appendLog("[iOS] log cleared")
    }

    private func startStatusTimer() {
        statusTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0,
            repeats: true
        ) { [weak self] _ in
            self?.refreshStatus()
        }
        refreshStatus()
    }

    private func refreshStatus() {
        guard let ptr = OFStatusJSON() else { return }
        let string = String(cString: ptr)
        OFFreeString(ptr)

        guard let data = string.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let running = obj["running"] as? Bool ?? false
        let connected = obj["connected"] as? Bool ?? false
        let socks = obj["socksListening"] as? Bool ?? false
        let lastError = obj["lastError"] as? String ?? ""
        let kind = obj["transport"] as? String ?? ""

        let sent = (obj["bytesSent"] as? NSNumber)?.uint64Value ?? 0
        let received = (obj["bytesReceived"] as? NSNumber)?.uint64Value ?? 0
        let ps = (obj["packetsSent"] as? NSNumber)?.uint64Value ?? 0
        let pr = (obj["packetsRecv"] as? NSNumber)?.uint64Value ?? 0
        let reconnects = (obj["reconnects"] as? NSNumber)?.uint64Value ?? 0
        let uptime = (obj["uptimeMs"] as? NSNumber)?.int64Value ?? 0

        if !lastError.isEmpty {
            statusLabel.text = "● Error: \(lastError)"
        } else if connected {
            statusLabel.text = "● Transport connected (\(kind))"
        } else if running {
            statusLabel.text = "● Connecting (\(kind))…"
        } else {
            statusLabel.text = "● Stopped"
        }

        statsLabel.text = """
        SOCKS5: \(socks ? "127.0.0.1:1080 listening" : "stopped")
        ↑ \(formatBytes(sent)) / \(ps) packets
        ↓ \(formatBytes(received)) / \(pr) packets
        reconnects: \(reconnects)   uptime: \(formatDuration(uptime))
        """

        if running {
            connectButton.isEnabled = false
            disconnectButton.isEnabled = true
            testButton.isEnabled = true
        }
    }

    private func formatBytes(_ value: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(value))
    }

    private func formatDuration(_ ms: Int64) -> String {
        let seconds = max(0, ms / 1000)
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }

    private func appendLog(_ text: String, timestamp: Bool = true) {
        let rendered: String
        if timestamp {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            rendered = "[\(formatter.string(from: Date()))] \(text)"
        } else {
            rendered = text
        }

        if logView.text.isEmpty {
            logView.text = rendered
        } else if logView.text.hasSuffix("\n") {
            logView.text += rendered
        } else {
            logView.text += "\n" + rendered
        }

        if logView.text.utf16.count > 120_000 {
            let idx = logView.text.index(logView.text.startIndex, offsetBy: min(40_000, logView.text.count))
            logView.text = String(logView.text[idx...])
        }

        let length = logView.text.utf16.count
        if length > 0 {
            logView.scrollRangeToVisible(NSRange(location: length - 1, length: 1))
        }
    }

    private func saveSettings() {
        defaults.set(transportControl.selectedSegmentIndex, forKey: "transport")
        defaults.set(urlField.text ?? "", forKey: "yandexURL")
        defaults.set(maxTokenField.text ?? "", forKey: "maxToken")
        defaults.set(maxUIDField.text ?? "", forKey: "maxUID")
    }

    private func loadSettings() {
        let transport = defaults.integer(forKey: "transport")
        transportControl.selectedSegmentIndex = (transport == 1 ? 1 : 0)
        urlField.text = defaults.string(forKey: "yandexURL") ?? ""
        maxTokenField.text = defaults.string(forKey: "maxToken") ?? ""
        maxUIDField.text = defaults.string(forKey: "maxUID") ?? ""
    }
}
