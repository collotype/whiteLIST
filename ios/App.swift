import UIKit
import NetworkExtension

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

private struct TunnelStatus: Decodable {
    let running: Bool
    let transport: String
    let connected: Bool
    let lastError: String
    let bytesSent: UInt64
    let bytesReceived: UInt64
    let packetsSent: UInt64
    let packetsRecv: UInt64
    let droppedRecv: UInt64
    let reconnects: UInt64
    let uptimeMs: Int64
}

final class ViewController: UIViewController {
    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var latestStatus: TunnelStatus?
    private var internetVerified = false
    private var probeInFlight = false
    private var lastProbe = Date.distantPast
    private var connectAfterSave = false

    private var tunnelBundleIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "com.collotype.whitelist") + ".tunnel"
    }

    private let statusDot = UIView()
    private let statusLabel = UILabel()
    private let detailLabel = UILabel()
    private let statsLabel = UILabel()
    private let connectButton = UIButton(type: .system)
    private let settingsButton = UIButton(type: .system)
    private let settingsStack = UIStackView()
    private let transportControl = UISegmentedControl(items: ["Yandex", "MAX"])
    private let urlField = ViewController.field("Ссылка на Yandex Docs", keyboard: .URL)
    private let tokenField = ViewController.field("MAX token", secure: true)
    private let uidField = ViewController.field("UID выходного узла", keyboard: .numberPad)
    private let saveButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "whiteLIST"
        view.backgroundColor = UIColor(red: 0.055, green: 0.047, blue: 0.082, alpha: 1)
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationController?.navigationBar.titleTextAttributes = [.foregroundColor: UIColor.white]
        navigationController?.navigationBar.largeTitleTextAttributes = [.foregroundColor: UIColor.white]

        buildUI()
        loadManager()
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.internetVerified = false
            self?.refresh()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        timer?.invalidate()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private static func field(
        _ placeholder: String,
        keyboard: UIKeyboardType = .default,
        secure: Bool = false
    ) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.keyboardType = keyboard
        field.isSecureTextEntry = secure
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.textColor = .white
        field.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        field.layer.cornerRadius = 12
        field.setLeftPadding(12)
        field.heightAnchor.constraint(equalToConstant: 48).isActive = true
        return field
    }

    private func buildUI() {
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.layer.cornerRadius = 6
        statusDot.backgroundColor = .systemGray
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 12),
            statusDot.heightAnchor.constraint(equalToConstant: 12)
        ])

        statusLabel.text = "Загрузка…"
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 22, weight: .bold)

        detailLabel.textColor = UIColor.white.withAlphaComponent(0.62)
        detailLabel.font = .systemFont(ofSize: 14)
        detailLabel.numberOfLines = 0

        statsLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        statsLabel.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        statsLabel.numberOfLines = 0
        statsLabel.text = "↑ 0 Б   ↓ 0 Б"

        connectButton.configuration = .filled()
        connectButton.configuration?.cornerStyle = .large
        connectButton.configuration?.baseBackgroundColor = UIColor(red: 0.64, green: 0.42, blue: 0.95, alpha: 1)
        connectButton.configuration?.contentInsets = .init(top: 16, leading: 24, bottom: 16, trailing: 24)
        connectButton.titleLabel?.font = .systemFont(ofSize: 18, weight: .bold)
        connectButton.setTitle("Подключить", for: .normal)
        connectButton.addTarget(self, action: #selector(connectTapped), for: .touchUpInside)

        settingsButton.setTitle("Настройка", for: .normal)
        settingsButton.tintColor = UIColor(red: 0.76, green: 0.63, blue: 1, alpha: 1)
        settingsButton.addTarget(self, action: #selector(toggleSettings), for: .touchUpInside)

        let statusRow = UIStackView(arrangedSubviews: [statusDot, statusLabel, UIView()])
        statusRow.axis = .horizontal
        statusRow.alignment = .center
        statusRow.spacing = 10

        let card = UIStackView(arrangedSubviews: [statusRow, detailLabel, statsLabel])
        card.axis = .vertical
        card.spacing = 10
        card.isLayoutMarginsRelativeArrangement = true
        card.layoutMargins = .init(top: 20, left: 20, bottom: 20, right: 20)
        card.backgroundColor = UIColor.white.withAlphaComponent(0.07)
        card.layer.cornerRadius = 20

        transportControl.selectedSegmentIndex = 0
        transportControl.selectedSegmentTintColor = UIColor(red: 0.64, green: 0.42, blue: 0.95, alpha: 1)
        transportControl.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        transportControl.addTarget(self, action: #selector(transportChanged), for: .valueChanged)

        saveButton.configuration = .bordered()
        saveButton.configuration?.cornerStyle = .large
        saveButton.configuration?.baseForegroundColor = UIColor(red: 0.76, green: 0.63, blue: 1, alpha: 1)
        saveButton.setTitle("Сохранить", for: .normal)
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)

        settingsStack.axis = .vertical
        settingsStack.spacing = 10
        settingsStack.addArrangedSubview(transportControl)
        settingsStack.addArrangedSubview(urlField)
        settingsStack.addArrangedSubview(tokenField)
        settingsStack.addArrangedSubview(uidField)
        settingsStack.addArrangedSubview(saveButton)
        settingsStack.isHidden = true

        let note = UILabel()
        note.text = "Параметры сохраняются в конфигурации VPN — повторно вводить их при каждом запуске не нужно."
        note.textColor = UIColor.white.withAlphaComponent(0.42)
        note.font = .systemFont(ofSize: 12)
        note.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [card, connectButton, settingsButton, settingsStack, note])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 16
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24)
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        transportChanged()
    }

    private func loadManager() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.showError("Не удалось загрузить VPN: \(error.localizedDescription)")
                    return
                }
                self.manager = managers?.first(where: {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.tunnelBundleIdentifier
                }) ?? NETunnelProviderManager()
                self.loadSavedConfiguration()
                self.refresh()
            }
        }
    }

    private func loadSavedConfiguration() {
        guard let configuration = manager?.protocolConfiguration as? NETunnelProviderProtocol,
              let values = configuration.providerConfiguration else {
            settingsStack.isHidden = false
            detailLabel.text = "Заполните настройку один раз"
            return
        }
        let kind = values["transport"] as? String ?? "yandex"
        transportControl.selectedSegmentIndex = kind == "max" ? 1 : 0
        urlField.text = values["url"] as? String ?? ""
        tokenField.text = values["token"] as? String ?? ""
        uidField.text = values["uid"] as? String ?? ""
        transportChanged()
    }

    @objc private func connectTapped() {
        guard let manager else { return }
        switch manager.connection.status {
        case .connected, .connecting, .reasserting:
            manager.connection.stopVPNTunnel()
        case .disconnecting:
            break
        case .disconnected, .invalid:
            guard hasValidSavedConfiguration else {
                connectAfterSave = true
                settingsStack.isHidden = false
                showError("Сначала сохраните параметры подключения")
                return
            }
            do {
                internetVerified = false
                try manager.connection.startVPNTunnel()
            } catch {
                showError("VPN не запустился: \(error.localizedDescription)")
            }
        @unknown default:
            break
        }
        refresh()
    }

    private var hasValidSavedConfiguration: Bool {
        guard let configuration = manager?.protocolConfiguration as? NETunnelProviderProtocol,
              let values = configuration.providerConfiguration,
              let kind = values["transport"] as? String else { return false }
        if kind == "yandex" {
            return ((values["url"] as? String) ?? "").hasPrefix("https://")
        }
        return !((values["token"] as? String) ?? "").isEmpty && Int64((values["uid"] as? String) ?? "") != nil
    }

    @objc private func saveTapped() {
        view.endEditing(true)
        guard let manager else { return }

        let kind = transportControl.selectedSegmentIndex == 0 ? "yandex" : "max"
        let url = urlField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let token = tokenField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let uid = uidField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if kind == "yandex" && !url.hasPrefix("https://") {
            showError("Нужна полная HTTPS-ссылка на документ Yandex")
            return
        }
        if kind == "max" && (token.isEmpty || (Int64(uid) ?? 0) <= 0) {
            showError("Укажите token и UID выходного узла MAX")
            return
        }

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = tunnelBundleIdentifier
        proto.serverAddress = "OpenFlux"
        proto.providerConfiguration = [
            "transport": kind,
            "url": url,
            "token": token,
            "uid": uid
        ]
        manager.protocolConfiguration = proto
        manager.localizedDescription = "whiteLIST"
        manager.isEnabled = true

        saveButton.isEnabled = false
        manager.saveToPreferences { [weak self] error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async {
                    self.saveButton.isEnabled = true
                    self.showError("Не удалось сохранить VPN: \(error.localizedDescription)")
                }
                return
            }
            manager.loadFromPreferences { error in
                DispatchQueue.main.async {
                    self.saveButton.isEnabled = true
                    if let error {
                        self.showError("Не удалось перечитать VPN: \(error.localizedDescription)")
                        return
                    }
                    self.settingsStack.isHidden = true
                    if self.connectAfterSave {
                        self.connectAfterSave = false
                        self.connectTapped()
                    } else {
                        self.detailLabel.text = "Настройка сохранена"
                    }
                }
            }
        }
    }

    @objc private func toggleSettings() {
        settingsStack.isHidden.toggle()
    }

    @objc private func transportChanged() {
        let yandex = transportControl.selectedSegmentIndex == 0
        urlField.isHidden = !yandex
        tokenField.isHidden = yandex
        uidField.isHidden = yandex
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    private func refresh() {
        guard let connection = manager?.connection else {
            renderOSStatus(.invalid)
            return
        }
        renderOSStatus(connection.status)
        guard connection.status == .connected else {
            latestStatus = nil
            internetVerified = false
            return
        }
        queryProviderStatus { [weak self] status in
            guard let self, let status else { return }
            self.latestStatus = status
            self.renderOSStatus(connection.status)
            if status.connected, !self.probeInFlight, Date().timeIntervalSince(self.lastProbe) >= 10 {
                self.verifyInternet(before: status)
            }
        }
    }

    private func queryProviderStatus(completion: @escaping (TunnelStatus?) -> Void) {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            completion(nil)
            return
        }
        do {
            try session.sendProviderMessage(Data("status".utf8)) { data in
                let status = data.flatMap { try? JSONDecoder().decode(TunnelStatus.self, from: $0) }
                DispatchQueue.main.async { completion(status) }
            }
        } catch {
            completion(nil)
        }
    }

    private func verifyInternet(before: TunnelStatus) {
        probeInFlight = true
        lastProbe = Date()
        var request = URLRequest(url: URL(string: "https://1.1.1.1/cdn-cgi/trace?whiteLIST=\(Int(Date().timeIntervalSince1970))")!)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 8
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        URLSession(configuration: configuration).dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.queryProviderStatus { after in
                    self.probeInFlight = false
                    let httpOK = (response as? HTTPURLResponse).map { 200..<400 ~= $0.statusCode } ?? false
                    let tunnelMoved = after.map {
                        $0.bytesReceived > before.bytesReceived && $0.packetsRecv > before.packetsRecv
                    } ?? false
                    self.internetVerified = error == nil && httpOK && tunnelMoved
                    if let after { self.latestStatus = after }
                    self.renderOSStatus(self.manager?.connection.status ?? .invalid)
                }
            }
        }.resume()
    }

    private func renderOSStatus(_ status: NEVPNStatus) {
        connectButton.isEnabled = manager != nil && status != .disconnecting
        switch status {
        case .connected:
            connectButton.setTitle("Отключить", for: .normal)
            if let tunnel = latestStatus, !tunnel.lastError.isEmpty {
                setStatus("Ошибка", detail: tunnel.lastError, color: .systemRed)
            } else if latestStatus?.connected != true {
                setStatus("Подключение…", detail: "Ожидание канала OpenFlux", color: .systemOrange)
            } else if internetVerified {
                setStatus("Работает", detail: "Интернет проверен через OpenFlux", color: .systemGreen)
            } else {
                setStatus("Проверка…", detail: "Канал поднят, проверяем реальный трафик", color: .systemOrange)
            }
        case .connecting, .reasserting:
            connectButton.setTitle("Отключить", for: .normal)
            setStatus("Подключение…", detail: "Запуск VPN и транспорта", color: .systemOrange)
        case .disconnecting:
            connectButton.setTitle("Отключение…", for: .normal)
            setStatus("Отключение…", detail: "", color: .systemOrange)
        case .disconnected:
            connectButton.setTitle("Подключить", for: .normal)
            setStatus("Отключено", detail: hasValidSavedConfiguration ? "Готово к подключению" : "Откройте настройку", color: .systemGray)
        case .invalid:
            connectButton.setTitle("Подключить", for: .normal)
            setStatus("Не настроено", detail: "Сохраните параметры подключения", color: .systemGray)
        @unknown default:
            setStatus("Неизвестно", detail: "", color: .systemGray)
        }

        if let tunnel = latestStatus {
            statsLabel.text = "↑ \(formatBytes(tunnel.bytesSent))   ↓ \(formatBytes(tunnel.bytesReceived))\nпакеты: \(tunnel.packetsSent) / \(tunnel.packetsRecv)   потери: \(tunnel.droppedRecv)"
        } else {
            statsLabel.text = "↑ 0 Б   ↓ 0 Б"
        }
    }

    private func setStatus(_ title: String, detail: String, color: UIColor) {
        statusLabel.text = title
        detailLabel.text = detail
        statusDot.backgroundColor = color
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "whiteLIST", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

private extension UITextField {
    func setLeftPadding(_ value: CGFloat) {
        let spacer = UIView(frame: CGRect(x: 0, y: 0, width: value, height: 1))
        leftView = spacer
        leftViewMode = .always
    }
}
