import Foundation
import Network
import CoreWLAN
import Darwin

/// Same-WiFi Auto-Discovery & Network State Monitor
///
/// IMPORTANT ARCHITECTURE NOTE:
/// Port `10152` on the phone is the SCP cryptographic handshake listener (`scp_connection_manager`).
/// We must NEVER open raw TCP probes (`connect()` + `close()`) to port `10152`, because an empty TCP
/// connection causes the phone's `scp_connection_manager` to block for 10-15s waiting for `Handshake Hello`
/// (`error_code: 2541 Handshake Hello timeout`), preventing the phone from popping up the connection dialog!
/// Instead, discovery relies on `O+Connect Service` (`LanSdpClient` UDP 10150 + `onAgentFound`) and
/// passive Bonjour `_oppo-ln-auth._tcp` metadata inspection.
public final class LanSdpDiscovery: @unchecked Sendable {
    public let bonjourServiceType = "_oppo-ln-auth._tcp"
    public let sdpMulticastGroup = "239.255.255.250"
    public let sdpPort: UInt16 = 10150
    public let accessoryPort: UInt16 = 10152

    private let queue = DispatchQueue(label: "com.colordrop.discovery", qos: .utility)
    private var pathMonitor: NWPathMonitor?
    private var bonjourBrowser: NWBrowser?
    private var periodicTimer: DispatchSourceTimer?

    public var onWiFiChanged: ((String, String) -> Void)? // (ssid, localIP)
    public var onDeviceDiscovered: ((OppoDevice) -> Void)?

    private(set) public var currentSSID: String = "当前 Wi-Fi"
    private(set) public var localIPv4: String = "127.0.0.1"
    private(set) public var localAllIPs: Set<String> = ["127.0.0.1", "::1", "localhost"]
    private(set) public var localDeviceId: String = "102ABC815501"
    private var localServiceName: String = "Mac-Connect-102ABC"

    public var hasValidLANIP: Bool {
        !localIPv4.isEmpty && localIPv4 != "127.0.0.1" && !localIPv4.hasPrefix("169.254.")
    }

    public init() {
        self.localDeviceId = Self.computeLocalDeviceId()
        self.localServiceName = "Mac-Connect-\(localDeviceId.prefix(6))"
        let (primaryIP, allIPs) = Self.detectAllLocalIPs()
        self.localIPv4 = primaryIP ?? "127.0.0.1"
        self.localAllIPs = allIPs
        self.currentSSID = Self.detectCurrentSSID()
    }

    public func updateLocalDeviceId(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "000000" else { return }
        self.localDeviceId = trimmed
        self.localServiceName = "Mac-Connect-\(trimmed.prefix(6))"
    }

    /// Generates a deterministic 12-character uppercase hex `device_id` for a LAN IPv4 address.
    public static func deterministicDeviceId(forIP ip: String) -> String {
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        if parts.count == 4 {
            return String(format: "10%02X%02X%02X%02X01", parts[0], parts[1], parts[2], parts[3])
        }
        return "10C0A81FD701"
    }

    // MARK: - Start / Stop Auto-Discovery

    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.refreshNetworkState()
            self.startPathMonitor()
            self.startBonjourDiscovery()
            self.startPeriodicNetworkCheck()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pathMonitor?.cancel()
            self.pathMonitor = nil
            self.bonjourBrowser?.cancel()
            self.bonjourBrowser = nil
            self.periodicTimer?.cancel()
            self.periodicTimer = nil
        }
    }

    public func triggerImmediateScan() {
        queue.async { [weak self] in
            guard let self else { return }
            self.refreshNetworkState()
        }
    }

    // MARK: - Check if an IP / Device belongs to this Mac

    public func isSelfAddress(_ ip: String, serviceName: String? = nil, deviceId: String? = nil) -> Bool {
        let clean = ip.split(separator: "%").first.map(String.init) ?? ip
        if clean.isEmpty || clean == "0.0.0.0" || clean.hasPrefix("127.") || clean == "::1" {
            return true
        }
        if clean == localIPv4 || localAllIPs.contains(clean) {
            return true
        }
        if let name = serviceName, (name == localServiceName || name.hasPrefix("OPPO-Lite-") || name.hasPrefix("Mac-Connect-")) {
            return true
        }
        if let id = deviceId, id == localDeviceId {
            return true
        }
        return false
    }

    // MARK: - Wi-Fi & IPv4 Detection

    private func refreshNetworkState() {
        let (primaryIP, allIPs) = Self.detectAllLocalIPs()
        let newIP = primaryIP ?? "127.0.0.1"
        let newSSID = Self.detectCurrentSSID()
        let changed = (newIP != localIPv4 || newSSID != currentSSID)
        localIPv4 = newIP
        localAllIPs = allIPs
        currentSSID = newSSID
        if changed {
            onWiFiChanged?(currentSSID, localIPv4)
        }
    }

    private func startPathMonitor() {
        pathMonitor?.cancel()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            guard let self else { return }
            self.refreshNetworkState()
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    // MARK: - Passive Bonjour `_oppo-ln-auth._tcp` Browser (Using UDP Endpoint Resolution — Never TCP Connect!)

    private func startBonjourDiscovery() {
        bonjourBrowser?.cancel()
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: bonjourServiceType, domain: "local.")
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: descriptor, using: params)

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            for result in results {
                if case let .service(name, type, domain, _) = result.endpoint {
                    if name == self.localServiceName || name.hasPrefix("OPPO-Lite-") || name.hasPrefix("Mac-Connect-") {
                        continue
                    }
                    if case let .bonjour(txt) = result.metadata {
                        if txt["device_id"] == self.localDeviceId || txt["device_type"] == "mac" {
                            continue
                        }
                    }
                    self.resolveBonjourEndpointViaUDP(name: name, type: type, domain: domain, metadata: result.metadata)
                }
            }
        }
        browser.start(queue: queue)
        bonjourBrowser = browser
    }

    /// Resolves the Bonjour service's IP address using `.udp` instead of `.tcp` so we NEVER open
    /// a dummy TCP connection to the phone's SCP port 10152!
    private func resolveBonjourEndpointViaUDP(name: String, type: String, domain: String, metadata: NWBrowser.Result.Metadata) {
        let endpoint = NWEndpoint.service(name: name, type: type, domain: domain, interface: nil)
        let conn = NWConnection(to: endpoint, using: .udp)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state,
               let innerEndpoint = conn.currentPath?.remoteEndpoint,
               case let .hostPort(host, port) = innerEndpoint {
                let rawHost = "\(host)"
                let cleanIP = rawHost.split(separator: "%").first.map(String.init) ?? rawHost
                var devName = name
                var devId = Self.deterministicDeviceId(forIP: cleanIP)
                if case let .bonjour(txt) = metadata {
                    devName = txt["device_name"] ?? txt["model"] ?? name
                    if let rawId = txt["device_id"], !rawId.isEmpty {
                        devId = rawId
                    }
                }
                if !self.isSelfAddress(cleanIP, serviceName: name, deviceId: devId) {
                    let device = OppoDevice(
                        deviceId: devId,
                        deviceName: devName,
                        lanIP: cleanIP,
                        port: Int(port.rawValue),
                        connectType: 16,
                        ssid: self.currentSSID,
                        isPaired: false,
                        isSameAccount: false,
                        discoverySource: .bonjour
                    )
                    self.onDeviceDiscovered?(device)
                }
                conn.cancel()
            }
        }
        conn.start(queue: queue)
    }

    private func startPeriodicNetworkCheck() {
        periodicTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 4.0, repeating: 6.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.refreshNetworkState()
        }
        timer.resume()
        periodicTimer = timer
    }

    /// Checks a specific LAN IP using ICMP ping (never touching TCP port 10152).
    public func probeDirectPeer(ip: String, port: Int = 10152, knownName: String? = nil, completion: @escaping (OppoDevice?) -> Void) {
        if isSelfAddress(ip) {
            completion(nil)
            return
        }
        let currentWifi = self.currentSSID
        DispatchQueue.global(qos: .userInitiated).async {
            if MemoryTelemetry.measureICMPLatencyMs(ip: ip) != nil {
                let dev = OppoDevice(
                    deviceId: Self.deterministicDeviceId(forIP: ip),
                    deviceName: knownName ?? "局域网设备 (\(ip))",
                    lanIP: ip,
                    port: port,
                    connectType: 16,
                    ssid: currentWifi,
                    isPaired: false,
                    isSameAccount: false,
                    discoverySource: .manualLAN
                )
                completion(dev)
            } else {
                completion(nil)
            }
        }
    }

    // MARK: - System Helpers

    public static func computeLocalDeviceId() -> String {
        return "102ABC815501"
    }

    public static func detectCurrentSSID() -> String {
        if let iface = CWWiFiClient.shared().interface(),
           let ssid = iface.ssid(),
           !ssid.isEmpty,
           !ssid.lowercased().contains("error"),
           !ssid.hasPrefix("-") {
            return ssid
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        task.arguments = ["-getairportnetwork", "en0"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !out.lowercased().contains("error"),
               !out.lowercased().contains("not associated"),
               let idx = out.range(of: ": ") {
                let ssid = String(out[idx.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !ssid.isEmpty && !ssid.lowercased().contains("error") && !ssid.hasPrefix("-") {
                    return ssid
                }
            }
        } catch {}
        return "当前 Wi-Fi"
    }

    public static func detectLocalIPv4() -> String? {
        detectAllLocalIPs().primary
    }

    public static func detectAllLocalIPs() -> (primary: String?, all: Set<String>) {
        var primary: String?
        var all: Set<String> = ["127.0.0.1", "::1", "localhost"]
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return (nil, all) }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            let interface = current.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) || addrFamily == UInt8(AF_INET6) {
                let name = String(cString: interface.ifa_name)
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(
                    interface.ifa_addr,
                    socklen_t(interface.ifa_addr.pointee.sa_len),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    socklen_t(0),
                    NI_NUMERICHOST
                )
                let rawIP = String(cString: hostname)
                let cleanIP = rawIP.split(separator: "%").first.map(String.init) ?? rawIP
                if !cleanIP.isEmpty {
                    all.insert(cleanIP)
                    if addrFamily == UInt8(AF_INET) && !cleanIP.hasPrefix("127.") && !cleanIP.hasPrefix("169.254.") {
                        if name == "en0" || name == "en1" || primary == nil {
                            primary = cleanIP
                        }
                    }
                }
            }
            ptr = interface.ifa_next
        }
        return (primary, all)
    }
}
