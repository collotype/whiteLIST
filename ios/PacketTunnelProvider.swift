import Foundation
import NetworkExtension
import Darwin

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let stateLock = NSLock()
    private let receiveQueue = DispatchQueue(label: "whiteLIST.packet.receive", qos: .userInitiated)
    private var active = false

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        receiveQueue.async { [weak self] in
            guard let self else { return }
            guard let configuration = (self.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
                  let transport = configuration["transport"] as? String else {
                completionHandler(TunnelError.invalidConfiguration)
                return
            }

            let result: Int32
            if transport == "max" {
                let token = configuration["token"] as? String ?? ""
                let uid = Int64(configuration["uid"] as? String ?? "") ?? 0
                result = token.withCString { OFStartMax(UnsafeMutablePointer(mutating: $0), uid) }
            } else {
                let url = configuration["url"] as? String ?? ""
                result = url.withCString { OFStartYandex(UnsafeMutablePointer(mutating: $0)) }
            }
            guard result == 0 else {
                completionHandler(TunnelError.transportStart(Int(result)))
                return
            }

            guard self.waitForTransport(timeout: 30) else {
                _ = OFStop()
                completionHandler(TunnelError.transportTimeout)
                return
            }

            let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "OpenFlux")
            let ipv4 = NEIPv4Settings(addresses: ["10.10.10.2"], subnetMasks: ["255.255.255.0"])
            ipv4.includedRoutes = [NEIPv4Route.default()]
            ipv4.excludedRoutes = [
                NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),
                NEIPv4Route(destinationAddress: "127.0.0.0", subnetMask: "255.0.0.0"),
                NEIPv4Route(destinationAddress: "169.254.0.0", subnetMask: "255.255.0.0"),
                NEIPv4Route(destinationAddress: "172.16.0.0", subnetMask: "255.240.0.0"),
                NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0"),
                NEIPv4Route(destinationAddress: "77.88.8.8", subnetMask: "255.255.255.255"),
                NEIPv4Route(destinationAddress: "77.88.8.1", subnetMask: "255.255.255.255")
            ]
            settings.ipv4Settings = ipv4
            let dns = NEDNSSettings(servers: ["77.88.8.8", "77.88.8.1"])
            dns.matchDomains = [""]
            settings.dnsSettings = dns
            settings.mtu = 1200

            self.setTunnelNetworkSettings(settings) { error in
                if let error {
                    _ = OFStop()
                    completionHandler(error)
                    return
                }
                self.setActive(true)
                self.readDevicePackets()
                self.receiveQueue.async { [weak self] in self?.receiveTunnelPackets() }
                completionHandler(nil)
            }
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        setActive(false)
        receiveQueue.async {
            _ = OFStop()
            completionHandler()
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let pointer = OFStatusJSON() else {
            completionHandler?(nil)
            return
        }
        let data = Data(bytes: pointer, count: strlen(pointer))
        OFFreeString(pointer)
        completionHandler?(data)
    }

    private func readDevicePackets() {
        guard isActive else { return }
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self, self.isActive else { return }
            for (packet, family) in zip(packets, protocols) where family.int32Value == AF_INET {
                guard !packet.isEmpty, packet.count <= 65_535 else { continue }
                packet.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress else { return }
                    _ = OFSendPacket(UnsafeMutableRawPointer(mutating: base), Int32(packet.count))
                }
            }
            self.readDevicePackets()
        }
    }

    private func receiveTunnelPackets() {
        while isActive {
            var length: Int32 = 0
            guard let pointer = OFReceivePacket(&length, 250), length > 0 else { continue }
            let packet = Data(bytes: pointer, count: Int(length))
            OFFreeBuffer(pointer)
            packetFlow.writePackets([packet], withProtocols: [NSNumber(value: AF_INET)])
        }
    }

    private func waitForTransport(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let pointer = OFStatusJSON() else { return false }
            let json = String(cString: pointer)
            OFFreeString(pointer)
            if let data = json.data(using: .utf8),
               let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               value["connected"] as? Bool == true {
                return true
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    private var isActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return active
    }

    private func setActive(_ value: Bool) {
        stateLock.lock()
        active = value
        stateLock.unlock()
    }
}

private enum TunnelError: LocalizedError {
    case invalidConfiguration
    case transportStart(Int)
    case transportTimeout

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "OpenFlux VPN configuration is missing"
        case .transportStart(let code):
            return "OpenFlux transport failed to start (\(code))"
        case .transportTimeout:
            return "OpenFlux transport did not connect within 30 seconds"
        }
    }
}
