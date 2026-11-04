import Foundation
import Darwin
import zlib

/// Native Swift client for O+Connect Core Daemon Unix Domain Sockets:
/// - `/tmp/oppolite-dspc` (HTTP-over-UDS control plane)
/// - `/tmp/oppolite-evnt` (Event stream for `connect_callback`, `onAgentFound`, `onAgentLost`, `onPeerDeviceInfoChanged`, `databus_callback`, `agent_callback`)
public final class DspIPCClient: @unchecked Sendable {
    public static let shared = DspIPCClient()

    public let dspSocketPath = "/tmp/oppolite-dspc"
    public let eventSocketPath = "/tmp/oppolite-evnt"
    public let sandboxDirPath = "/tmp/oppolite-oppodat"
    public var runtimeDaemonBinaryPath: String {
        sandboxDirPath + "/O+Connect Service"
    }

    private var isListeningEvents = false
    private var isLaunchingDaemon = false
    private var needsDaemonRestart = false
    private let lock = NSLock()
    private var registeredAppId: Int?
    private var daemonProcess: Process?

    public var onConnectEvent: (([String: Any]) -> Void)?
    public var onDiscoveryEvent: (([String: Any]) -> Void)?
    public var onDeviceLostEvent: (([String: Any]) -> Void)?
    public var onPeerDeviceInfoChanged: (([String: Any]) -> Void)?
    public var onDataBusEvent: (([String: Any]) -> Void)?
    public var onAgentConnected: ((String) -> Void)?
    public var onAgentDisconnected: ((String) -> Void)?
    public var onAgentMessage: ((String, [String: Any]) -> Void)?

    public init() {
        prepareDaemonBinaryIfNeeded()
    }

    /// Unmasks IP addresses masked by `O+Connect Service` (e.g. `"*.*.31.162:10152"` -> `"192.168.31.162:10152"`)
    /// using the first two octets of the Mac's current Wi-Fi IPv4 address.
    public static func unmaskDaemonIP(_ rawAddress: String, localIP: String) -> String {
        guard rawAddress.hasPrefix("*.*.") else { return rawAddress }
        let localParts = localIP.split(separator: ".")
        let prefix = localParts.count == 4 ? "\(localParts[0]).\(localParts[1])." : "192.168."
        return prefix + rawAddress.dropFirst(4)
    }

    /// Locates the bundled or system `O+Connect Service` binary across all deployment environments.
    public func locateSourceDaemonBinaryPath() -> String? {
        let execDir = URL(fileURLWithPath: CommandLine.arguments.first ?? Bundle.main.executablePath ?? "")
            .deletingLastPathComponent()
        let inferredBundleVendor = execDir
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Vendor/O+Connect Service")
            .path

        let candidates = [
            Bundle.main.bundlePath + "/Contents/Resources/Vendor/O+Connect Service",
            inferredBundleVendor,
            FileManager.default.currentDirectoryPath + "/Vendor/O+Connect Service",
            "/Applications/ColorDrop.app/Contents/Resources/Vendor/O+Connect Service",
            "/Applications/O+ Connect.app/Contents/Resources/daemon/O+Connect Service",
            "/Library/Application Support/O+Connect/O+Connect Service"
        ]
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0) })
    }

    // MARK: - Prepare Universal `/tmp/oppolite-oppodat` Sandbox & Code-Signed Daemon Binary

    public func prepareDaemonBinaryIfNeeded() {
        prepareUserSandboxDirectory()

        let fm = FileManager.default
        if let srcPath = locateSourceDaemonBinaryPath() {
            let dstPath = runtimeDaemonBinaryPath
            let srcSize = (try? fm.attributesOfItem(atPath: srcPath)[.size] as? Int64) ?? 0
            let dstSize = (try? fm.attributesOfItem(atPath: dstPath)[.size] as? Int64) ?? -1
            if !fm.fileExists(atPath: dstPath) || srcSize != dstSize {
                try? fm.removeItem(atPath: dstPath)
                try? fm.copyItem(atPath: srcPath, toPath: dstPath)
                chmod(dstPath, 0o755)
            }
        }

        var targetPaths: [String] = []
        if fm.fileExists(atPath: runtimeDaemonBinaryPath) {
            targetPaths.append(runtimeDaemonBinaryPath)
        }
        if let srcPath = locateSourceDaemonBinaryPath(),
           srcPath != runtimeDaemonBinaryPath,
           fm.isWritableFile(atPath: srcPath) {
            targetPaths.append(srcPath)
        }

        let replacements: [(Data, Data)] = [
            (Data("/tmp/oplus-dsp-ipc".utf8), Data("/tmp/oppolite-dspc".utf8)),
            (Data("/tmp/oppolite-dsp1".utf8), Data("/tmp/oppolite-dspc".utf8)),
            (Data("/tmp/dsp-ipc-event".utf8), Data("/tmp/oppolite-evnt".utf8)),
            (Data("/tmp/oppolite-evt1".utf8), Data("/tmp/oppolite-evnt".utf8)),
            (Data("/Library/Application Support/O+Connect".utf8), Data("/tmp/oppolite-oppodat/././././././././".utf8)),
            (Data("/Users/micage/Documents/Gemini/oppodat".utf8), Data("/tmp/oppolite-oppodat/././././././././".utf8)),
            (Data("Library/Application Support/O+Connect".utf8), Data("/tmp/oppolite-oppodat/./././././././.".utf8)),
            (Data("Documents/Gemini/oppodat/././././././".utf8), Data("/tmp/oppolite-oppodat/./././././././.".utf8)),
            (Data("/Library/Logs/devicespace-daemon".utf8), Data("/tmp/oppolite-dsplogs-daemon/./.".utf8)),
            (Data("/Documents/Gemini/dsplogs-daemon".utf8), Data("/tmp/oppolite-dsplogs-daemon/./.".utf8)),
            (Data("/Library/Logs/devicespace".utf8), Data("/tmp/oppolite-dsplogs/./.".utf8)),
            (Data("/Documents/Gemini/dsplogs".utf8), Data("/tmp/oppolite-dsplogs/./.".utf8)),
            (Data("oplus_remote_ui".utf8), Data("OppoLiteConnect".utf8))
        ]

        let bytePatches: [(offset: Int, orig: [UInt8], patch: [UInt8])] = [
            // 1. `is_need_restart` (0xd34e30): `mov w0, #0; ret`
            (0xd34e30, [0xff, 0x43, 0x01, 0xd1, 0xf4, 0x4f, 0x03, 0xa9], [0x00, 0x00, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6]),
            // 2. `check_local_network_permission` (0x318e94): `nop`
            (0x318e94, [0x65, 0x04, 0x00, 0x54], [0x1f, 0x20, 0x03, 0xd5]),
            // 3. `check_local_network_permission` closure (0xd121c): `mov w8, #0x1`
            (0xd121c, [0x08, 0x00, 0x40, 0x39], [0x28, 0x00, 0x80, 0x52]),
            // 4. `get_client_info_by_fd` (0xd79d64): `mov w8, #0x0`
            (0xd79d64, [0xe8, 0x66, 0x40, 0x39], [0x08, 0x00, 0x80, 0x52]),
            // 5. `IpcServer::start_server` (0xd5a25c): `nop`
            (0xd5a25c, [0x57, 0x13, 0x00, 0x36], [0x1f, 0x20, 0x03, 0xd5]),
            // 6. `get_log_config` (0xe117dc): `b 0x100e11870`
            (0xe117dc, [0xa2, 0x04, 0x00, 0x54], [0x25, 0x00, 0x00, 0x14]),
            // 7. `OafEventBusUvSocketLocal::__oafEvBusSocketRecvThreadInit` (0x6308b0): bind UDP 127.0.0.1:51743
            (0x6308b0, [0xc1, 0x43, 0x99, 0x52], [0xe1, 0x43, 0x99, 0x52]),
            // 8. `OafEventBusUvSocketLocal::__oafResourceFree` (0x63055c): `ret`
            (0x63055c, [0xf4, 0x4f, 0xbe, 0xa9], [0xc0, 0x03, 0x5f, 0xd6]),
            // 9. `network_state_monitor::get_ip` (0xd29960): use `en0` Wi-Fi LAN IP
            (0xd29960, [0xa5, 0x69, 0x00, 0x94, 0xe8, 0x03, 0x40, 0xf9, 0x1f, 0x09, 0x00, 0xf1], [0xb7, 0x5d, 0x00, 0xd0, 0xf7, 0x62, 0x32, 0x91, 0x2b, 0x00, 0x00, 0x14]),
            // 10. `init_discovery_proxy` (0x317cf0): `nop`
            (0x317cf0, [0x00, 0x04, 0x00, 0x36], [0x1f, 0x20, 0x03, 0xd5]),
            // 11. `verify_port_listening_via_command` (0xc4e420): `mov w0, #1; ret`
            (0xc4e420, [0xfc, 0x6f, 0xba, 0xa9, 0xfa, 0x67, 0x01, 0xa9], [0x20, 0x00, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6]),
            // 12. `discovery_open::closure` (0xcdd50): `nop`
            (0xcdd50, [0xe0, 0x0f, 0x00, 0x36], [0x1f, 0x20, 0x03, 0xd5]),
            // 13. `ConfigsIpcModule::on_client_death` (0xd3c348): `ret`
            (0xd3c348, [0xff, 0x03, 0x02, 0xd1], [0xc0, 0x03, 0x5f, 0xd6])
        ]

        for path in targetPaths where fm.isWritableFile(atPath: path) {
            guard var data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
            var modified = false

            for (oldBytes, newBytes) in replacements {
                assert(oldBytes.count == newBytes.count, "Replacement byte lengths must match")
                while let range = data.range(of: oldBytes) {
                    data.replaceSubrange(range, with: newBytes)
                    modified = true
                }
            }

            for item in bytePatches where data.count > item.offset + item.patch.count {
                let end = item.offset + item.patch.count
                let currentSlice = Array(data[item.offset..<end])
                if currentSlice == item.orig {
                    data.replaceSubrange(item.offset..<end, with: item.patch)
                    modified = true
                }
            }

            if modified {
                try? data.write(to: URL(fileURLWithPath: path))
                chmod(path, 0o755)
                adHocCodesignBinary(at: path)
                lock.lock()
                needsDaemonRestart = true
                lock.unlock()
            } else if !isBinarySignatureValid(at: path) {
                chmod(path, 0o755)
                adHocCodesignBinary(at: path)
            }
        }
    }

    private func prepareUserSandboxDirectory() {
        let fm = FileManager.default
        let dirs = [
            sandboxDirPath,
            sandboxDirPath + "/data",
            sandboxDirPath + "/send_tmp",
            sandboxDirPath + "/recv_tmp",
            "/tmp/oppolite-dsplogs-daemon",
            "/tmp/oppolite-dsplogs",
            "/tmp/devicespace"
        ]
        for dir in dirs {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            chmod(dir, 0o777)
        }

        let home = fm.homeDirectoryForCurrentUser.path
        let userFlagPath = sandboxDirPath + "/.user_path_flag"
        try? home.write(toFile: userFlagPath, atomically: true, encoding: .utf8)
        chmod(userFlagPath, 0o666)

        let targetDb = sandboxDirPath + "/ndsf.db"
        let sourceDbCandidates = [
            "/Library/Application Support/O+Connect/ndsf.db",
            home + "/Documents/Gemini/oppodat/ndsf.db"
        ]
        if !fm.fileExists(atPath: targetDb),
           let sourceDb = sourceDbCandidates.first(where: { fm.fileExists(atPath: $0) }) {
            try? fm.copyItem(atPath: sourceDb, toPath: targetDb)
        }

        let localInfoPath = sandboxDirPath + "/local_device_info.txt"
        var needsWrite = true
        if let existing = try? String(contentsOfFile: localInfoPath, encoding: .utf8),
           !existing.contains("[0,0,0,0,0,0]"),
           existing.contains("\"device_type_major\":11") {
            needsWrite = false
        }
        if needsWrite {
            let hexId = LanSdpDiscovery.computeLocalDeviceId()
            var byteArray: [Int] = []
            var idx = hexId.startIndex
            while idx < hexId.endIndex {
                let nextIdx = hexId.index(idx, offsetBy: 2, limitedBy: hexId.endIndex) ?? hexId.endIndex
                if let b = Int(hexId[idx..<nextIdx], radix: 16) {
                    byteArray.append(b)
                }
                idx = nextIdx
            }
            if byteArray.count != 6 {
                byteArray = [16, 42, 188, 129, 85, 1]
            }
            let bytesStr = byteArray.map(String.init).joined(separator: ",")
            let validDeviceJson = "{\"device_type_major\":11,\"serial_number\":\"C02\(hexId.prefix(9))\",\"device_id\":[\(bytesStr)],\"client_version\":\"17.20.0\"}"
            try? validDeviceJson.write(toFile: localInfoPath, atomically: true, encoding: .utf8)
        }
        chmod(localInfoPath, 0o666)

        if let items = try? fm.contentsOfDirectory(atPath: sandboxDirPath) {
            for item in items where item != "O+Connect Service" {
                let fullPath = sandboxDirPath + "/" + item
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: fullPath, isDirectory: &isDir) {
                    chmod(fullPath, isDir.boolValue ? 0o777 : 0o666)
                }
            }
        }
    }

    private func isBinarySignatureValid(at path: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        proc.arguments = ["-v", path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func adHocCodesignBinary(at path: String) {
        let xattrProc = Process()
        xattrProc.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattrProc.arguments = ["-cr", path]
        xattrProc.standardOutput = FileHandle.nullDevice
        xattrProc.standardError = FileHandle.nullDevice
        try? xattrProc.run()
        xattrProc.waitUntilExit()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        proc.arguments = ["--force", "--sign", "-", path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
    }

    // MARK: - Check & Launch Embedded Core Daemon (`O+Connect Service`)

    public var isDaemonAvailable: Bool {
        guard FileManager.default.fileExists(atPath: dspSocketPath) else { return false }
        return canConnectUnixSocket(path: dspSocketPath)
    }

    private func canConnectUnixSocket(path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                for i in 0..<pathBytes.count { dst[i] = pathBytes[i] }
            }
        }
        let res = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return res == 0
    }

    private var didAttemptRootDaemonCleanup = false

    private func cleanupConflictingRootDaemonIfNeeded() {
        lock.lock()
        if didAttemptRootDaemonCleanup {
            lock.unlock()
            return
        }
        didAttemptRootDaemonCleanup = true
        lock.unlock()

        guard FileManager.default.fileExists(atPath: "/tmp/oplus-dsp-ipc") else { return }
        let script = "do shell script \"launchctl bootout system/com.oplus.dsp.core 2>/dev/null; launchctl unload -w /Library/LaunchDaemons/com.oplus.dsp.core.plist 2>/dev/null; killall -9 'O+Connect Service' 2>/dev/null; rm -f /tmp/oplus-dsp-ipc /tmp/dsp-ipc-event\" with administrator privileges"
        let osa = Process()
        osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osa.arguments = ["-e", script]
        osa.standardOutput = FileHandle.nullDevice
        osa.standardError = FileHandle.nullDevice
        try? osa.run()
        osa.waitUntilExit()
    }

    /// Cleanly terminates the daemon and removes Unix sockets when ColorDrop quits so no orphan daemon is left running.
    public func terminateDaemonOnAppQuit() {
        DiagnosticLogService.shared.log("应用退出，正在清理守护进程与残留 Socket", category: "Daemon")
        daemonProcess?.terminate()
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killer.arguments = ["-9", "O+Connect Service"]
        killer.standardOutput = FileHandle.nullDevice
        killer.standardError = FileHandle.nullDevice
        try? killer.run()
        killer.waitUntilExit()
        unlink(dspSocketPath)
        unlink(eventSocketPath)
    }

    private func markNeedsDaemonRestart() {
        lock.lock()
        needsDaemonRestart = true
        lock.unlock()
    }

    /// Kills a zombie/half-dead `O+Connect Service` (e.g. `404 · 02-005-001: No socket is alive.`),
    /// cleans up stale sockets, and spawns a fresh daemon instance.
    public func forceRestartDaemon(reason: String) async {
        DiagnosticLogService.shared.log("触发守护进程强制自愈重启: \(reason)", level: "WARN", category: "Daemon")
        markNeedsDaemonRestart()
        ensureCoreDaemonRunning()
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if isDaemonAvailable { break }
        }
    }

    public func ensureCoreDaemonRunning() {
        prepareDaemonBinaryIfNeeded()
        lock.lock()
        let shouldForceRestart = needsDaemonRestart
        lock.unlock()

        if isDaemonAvailable && !shouldForceRestart {
            startEventSubscriptionsIfNeeded()
            return
        }
        lock.lock()
        if isLaunchingDaemon {
            lock.unlock()
            return
        }
        isLaunchingDaemon = true
        needsDaemonRestart = false
        lock.unlock()

        var candidatePaths: [String] = [runtimeDaemonBinaryPath]
        if let src = locateSourceDaemonBinaryPath() {
            candidatePaths.append(src)
        }
        guard let execPath = candidatePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            lock.lock()
            isLaunchingDaemon = false
            lock.unlock()
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.isLaunchingDaemon = false
                self.lock.unlock()
            }
            if shouldForceRestart || !self.isDaemonAvailable {
                self.cleanupConflictingRootDaemonIfNeeded()

                let killer = Process()
                killer.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
                killer.arguments = ["-9", "O+Connect Service"]
                killer.standardOutput = FileHandle.nullDevice
                killer.standardError = FileHandle.nullDevice
                try? killer.run()
                killer.waitUntilExit()

                unlink(self.dspSocketPath)
                unlink(self.eventSocketPath)

                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: execPath)
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                do {
                    try proc.run()
                    self.daemonProcess = proc
                    DiagnosticLogService.shared.log("已启动全新 O+Connect Service 守护进程 (PID: \(proc.processIdentifier))", category: "Daemon")
                    for _ in 0..<25 {
                        Thread.sleep(forTimeInterval: 0.2)
                        if self.isDaemonAvailable { break }
                    }
                } catch {
                    DiagnosticLogService.shared.log("启动守护进程失败: \(error.localizedDescription)", level: "ERROR", category: "Daemon")
                }
            }
            self.startEventSubscriptionsIfNeeded()
        }
    }

    // MARK: - Subscribe to `/tmp/oppolite-evnt` Event Channels

    public func startEventSubscriptionsIfNeeded() {
        lock.lock()
        if isListeningEvents || !FileManager.default.fileExists(atPath: eventSocketPath) {
            lock.unlock()
            return
        }
        isListeningEvents = true
        lock.unlock()

        subscribeEventChannel(eventId: "connect_callback") { [weak self] json in
            self?.onConnectEvent?(json)
        }
        // `onAgentFound` & `onAgentLost` carry the real phone model name (e.g. `OPPO Find X8`, `OnePlus 15`)
        subscribeEventChannel(eventId: "onAgentFound") { [weak self] json in
            self?.onDiscoveryEvent?(json)
        }
        subscribeEventChannel(eventId: "onAgentLost") { [weak self] json in
            self?.onDeviceLostEvent?(json)
        }
        subscribeEventChannel(eventId: "discovery_callback") { [weak self] json in
            self?.onDiscoveryEvent?(json)
        }
        // `onPeerDeviceInfoChanged` carries real-time `batteryInfo` (`{"batteryLevel": 83, "batteryCharging": 0}`)
        subscribeEventChannel(eventId: "onPeerDeviceInfoChanged") { [weak self] json in
            self?.onPeerDeviceInfoChanged?(json)
        }
        subscribeEventChannel(eventId: "databus_callback") { [weak self] json in
            self?.onDataBusEvent?(json)
        }
        subscribeEventChannel(eventId: "agent_callback") { [weak self] json in
            self?.handleRawAgentEvent(json)
        }
    }

    private func handleRawAgentEvent(_ dict: [String: Any]) {
        let event = (dict["event"] as? String) ?? ""
        let dataDict = dict["data"] as? [String: Any]
        let deviceId = (dict["device_id"] as? String)
            ?? (dataDict?["device_id"] as? String)
            ?? ""
        if event == "onAgentConnected" {
            onAgentConnected?(deviceId)
        } else if event == "onAgentDisconnected" {
            onAgentDisconnected?(deviceId)
        } else if event == "onAgentReceived" {
            let b64 = (dict["data"] as? String) ?? (dataDict?["data"] as? String)
            guard let b64 = b64,
                  let rawData = Data(base64Encoded: b64) else {
                return
            }
            let payloadData = Self.decompressGzipOrZlibIfNeeded(rawData)
            if let msgObj = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] {
                onAgentMessage?(deviceId, msgObj)
            } else if let str = String(data: payloadData, encoding: .utf8),
                      let trimmedData = str.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                      let msgObj = try? JSONSerialization.jsonObject(with: trimmedData) as? [String: Any] {
                onAgentMessage?(deviceId, msgObj)
            }
        }
    }

    /// Automatically decompresses GZIP (`0x1f 0x8b`) or ZLIB streams returned by `O+Connect Service` on `onAgentReceived`.
    public static func decompressGzipOrZlibIfNeeded(_ data: Data) -> Data {
        guard data.count >= 2 else { return data }
        let b0 = data[data.startIndex]
        let b1 = data[data.index(after: data.startIndex)]
        guard (b0 == 0x1f && b1 == 0x8b) || b0 == 0x78 else {
            return data
        }

        return data.withUnsafeBytes { rawBuf -> Data in
            guard let basePtr = rawBuf.bindMemory(to: Bytef.self).baseAddress else {
                return data
            }
            var stream = z_stream()
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: basePtr)
            stream.avail_in = uInt(rawBuf.count)

            let initStatus = inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard initStatus == Z_OK else { return data }
            defer { inflateEnd(&stream) }

            var decompressed = Data(capacity: max(data.count * 6, 65536))
            let chunkSize = 65536
            var outBuffer = [UInt8](repeating: 0, count: chunkSize)

            repeat {
                let status: Int32 = outBuffer.withUnsafeMutableBytes { outBuf in
                    stream.next_out = outBuf.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let have = chunkSize - Int(stream.avail_out)
                if have > 0 {
                    decompressed.append(outBuffer, count: have)
                }
                if status == Z_STREAM_END {
                    break
                }
                if status != Z_OK {
                    return decompressed.isEmpty ? data : decompressed
                }
            } while stream.avail_out == 0 || stream.avail_in > 0

            return decompressed.isEmpty ? data : decompressed
        }
    }

    private func subscribeEventChannel(eventId: String, handler: @escaping ([String: Any]) -> Void) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            while true {
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else {
                    Thread.sleep(forTimeInterval: 2.0)
                    continue
                }

                var addr = sockaddr_un()
                addr.sun_family = sa_family_t(AF_UNIX)
                let pathBytes = self.eventSocketPath.utf8CString
                guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
                    close(fd)
                    return
                }
                withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                        for i in 0..<pathBytes.count { dst[i] = pathBytes[i] }
                    }
                }

                let res = withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                if res != 0 {
                    close(fd)
                    Thread.sleep(forTimeInterval: 1.0)
                    continue
                }

                let handshake = "\(eventId)\n"
                _ = handshake.withCString { cstr in
                    Darwin.send(fd, cstr, strlen(cstr), 0)
                }

                var buffer = [UInt8](repeating: 0, count: 65536)
                var pending = Data()
                while true {
                    let n = Darwin.recv(fd, &buffer, buffer.count, 0)
                    if n <= 0 { break }
                    pending.append(buffer, count: n)
                    while let nl = pending.firstIndex(of: UInt8(ascii: "\n")) {
                        let lineData = pending.subdata(in: 0..<nl)
                        pending.removeSubrange(0...nl)
                        if let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                            if let msgStr = obj["msg"] as? String,
                               let msgData = msgStr.data(using: .utf8),
                               let inner = try? JSONSerialization.jsonObject(with: msgData) as? [String: Any] {
                                handler(inner)
                            } else {
                                handler(obj)
                            }
                        }
                    }
                }
                close(fd)
                Thread.sleep(forTimeInterval: 1.0)
            }
        }
    }

    // MARK: - Core HTTP-over-Unix-Socket Request (`IpcUri::to_uri` format)

    public func buildIpcUri(path: String, scope: Int = 1, params: [String: Any]? = nil) -> String {
        let b64: String
        if let params = params,
           let data = try? JSONSerialization.data(withJSONObject: params) {
            b64 = data.base64EncodedString()
        } else {
            b64 = ""
        }
        return "\(path)?scope=\(String(scope))&params=\(b64)"
    }

    public func request(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        timeoutMs: Int = 4000
    ) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.performUnixHTTPRequest(
                        socketPath: self.dspSocketPath,
                        path: path,
                        method: method,
                        body: body,
                        timeoutMs: timeoutMs
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func performUnixHTTPRequest(
        socketPath: String,
        path: String,
        method: String,
        body: Data?,
        timeoutMs: Int
    ) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "DspIPCClient", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "无法创建连接通道"])
        }
        defer { close(fd) }

        var tv = timeval(tv_sec: timeoutMs / 1000, tv_usec: Int32((timeoutMs % 1000) * 1000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw NSError(domain: "DspIPCClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Socket 路径过长"])
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                for i in 0..<pathBytes.count { dst[i] = pathBytes[i] }
            }
        }

        let connectRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectRes == 0 else {
            throw NSError(domain: "DspIPCClient", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "核心服务未就绪"])
        }

        let contentLength = body?.count ?? 0
        var header = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
        if contentLength > 0 {
            header += "Content-Type: application/json\r\nContent-Length: \(String(contentLength))\r\n"
        }
        header += "\r\n"

        var requestData = Data(header.utf8)
        if let body = body {
            requestData.append(body)
        }

        try requestData.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var sent = 0
            while sent < rawBuf.count {
                let n = Darwin.send(fd, base.advanced(by: sent), rawBuf.count - sent, 0)
                if n <= 0 {
                    throw NSError(domain: "DspIPCClient", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "发送请求失败"])
                }
                sent += n
            }
        }

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.recv(fd, &buffer, buffer.count, 0)
            if n > 0 {
                responseData.append(buffer, count: n)
            } else {
                break
            }
        }

        guard let rawString = String(data: responseData, encoding: .utf8) else {
            return [:]
        }
        let parts = rawString.components(separatedBy: "\r\n\r\n")
        let bodyString = parts.count > 1 ? parts.dropFirst().joined(separator: "\r\n\r\n") : rawString
        guard let bodyData = bodyString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return ["raw": bodyString]
        }
        return json
    }

    // MARK: - High-Level O+Connect Protocol APIs

    public func initializeCore() async throws -> [String: Any] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let uri = buildIpcUri(path: "/init", scope: 1, params: ["user_path": home])
        return try await request(path: uri, timeoutMs: 8000)
    }

    public func getLocalDeviceIdFromDaemon() async -> String? {
        guard isDaemonAvailable else { return nil }
        let uri = buildIpcUri(path: "/get_local_device", scope: 2, params: nil)
        guard let resp = try? await request(path: uri, timeoutMs: 2500),
              let status = resp["status"] as? Int, (status == 0 || status == 200),
              let dataStr = resp["data"] as? String,
              let data = dataStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devId = json["device_id"] as? String,
              !devId.isEmpty,
              devId != "000000" else {
            return nil
        }
        return devId
    }

    public func updateScreenUnlockState() async {
        let uriOn = buildIpcUri(path: "/update_device_status", scope: 9, params: [
            "status_name": "screen",
            "state": 1
        ])
        let uriUnlock = buildIpcUri(path: "/update_device_status", scope: 9, params: [
            "status_name": "screen",
            "state": 3
        ])
        _ = try? await request(path: uriOn, timeoutMs: 2500)
        _ = try? await request(path: uriUnlock, timeoutMs: 2500)
    }

    public func setDiscoveryActive(_ active: Bool) async throws -> [String: Any] {
        let uri = buildIpcUri(path: "/discovery_query", scope: 1, params: ["is": active ? 1 : 0])
        return try await request(path: uri, timeoutMs: 3000)
    }

    public func enableSenselessDiscovery(_ enabled: Bool = true) async {
        let uri = buildIpcUri(path: "/enable_senseless_discovery", scope: 1, params: ["enable": enabled])
        _ = try? await request(path: uri, timeoutMs: 2500)
    }

    /// Triggers `/discovery_query?scope=1&params={"is":1}` to flush the daemon's `publish_on_agent_found_no_repeatedly` filter
    /// AND verifies that the daemon's discovery socket has not died (`404 · 02-005-001: No socket is alive.`).
    @discardableResult
    public func probeDevicesAndCheckHealth() async -> (healthy: Bool, reason: String?) {
        guard isDaemonAvailable else {
            return (false, "IPC socket 不可达")
        }
        let uri = buildIpcUri(path: "/discovery_query", scope: 1, params: ["is": 1])
        do {
            let resp = try await request(path: uri, timeoutMs: 3000)
            let status = (resp["status"] as? Int) ?? 0
            let msg = (resp["msg"] as? String) ?? ""
            if status == 404 || msg.contains("02-005-001") || msg.contains("No socket is alive") {
                return (false, "discovery_query 异常 (\(status) · \(msg))")
            }
            return (true, nil)
        } catch {
            return (false, "discovery_query 请求超时: \(error.localizedDescription)")
        }
    }

    public func probeDevices() async {
        _ = await probeDevicesAndCheckHealth()
    }

    public static func buildFormattedQRCodeUrl(
        fromRawDaemonJson rawJsonString: String? = nil,
        localIP: String,
        ssid: String,
        deviceId: String
    ) -> String {
        let baseUrl = "https://pc-assistant-cn.allawnfs.com/h5/index.html"
        let hostName = Host.current().localizedName ?? "MacBook Pro"
        let encodedName = hostName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? hostName
        let cleanSSID = (ssid == "当前 Wi-Fi" || ssid == "未知网络" || ssid == "wired without ssid") ? "" : ssid
        let encodedSSID = cleanSSID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cleanSSID

        if let raw = rawJsonString,
           let data = raw.data(using: .utf8),
           var outer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           var lanConnect = outer["lan_connect"] as? [String: Any] {
            if let s = lanConnect["ssid"] as? String, !s.isEmpty, s != "wired without ssid" {
                lanConnect["ssid"] = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
            } else if !encodedSSID.isEmpty {
                lanConnect["ssid"] = encodedSSID
            }
            if let n = lanConnect["name"] as? String, !n.isEmpty {
                lanConnect["name"] = n.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? n
            } else {
                lanConnect["name"] = encodedName
            }
            if let addr = lanConnect["addr"] as? String, (addr.isEmpty || addr.hasPrefix(":")) {
                lanConnect["addr"] = "\(localIP):10152"
            }
            lanConnect["cp"] = "mac"
            lanConnect["lang"] = "zh-CN"
            outer["lan_connect"] = lanConnect
            if let outData = try? JSONSerialization.data(withJSONObject: outer),
               let outStr = String(data: outData, encoding: .utf8) {
                return "\(baseUrl)?param=\(outStr)"
            }
        }

        var lanDict: [String: Any] = [
            "addr": "\(localIP):10152",
            "dvd": deviceId,
            "d_type": 10,
            "name": encodedName,
            "model": "MacBookPro",
            "ver": 1,
            "cp": "mac",
            "lang": "zh-CN"
        ]
        if !encodedSSID.isEmpty {
            lanDict["ssid"] = encodedSSID
        }
        let wrapper: [String: Any] = ["lan_connect": lanDict]
        if let outData = try? JSONSerialization.data(withJSONObject: wrapper),
           let outStr = String(data: outData, encoding: .utf8) {
            return "\(baseUrl)?param=\(outStr)"
        }
        return "\(baseUrl)?param={\"lan_connect\":{\"addr\":\"\(localIP):10152\",\"dvd\":\"\(deviceId)\",\"d_type\":10,\"name\":\"Mac\",\"model\":\"MacBookPro\",\"ver\":1,\"cp\":\"mac\",\"lang\":\"zh-CN\"}}"
    }

    public func fetchQrCodeInfo(localIP: String, ssid: String, fallbackDeviceId: String) async -> String {
        guard isDaemonAvailable else {
            return Self.buildFormattedQRCodeUrl(
                fromRawDaemonJson: nil,
                localIP: localIP,
                ssid: ssid,
                deviceId: fallbackDeviceId
            )
        }
        let uri = buildIpcUri(path: "/get_qr_info", scope: 1, params: nil)
        if let resp = try? await request(path: uri, timeoutMs: 3000),
           let status = resp["status"] as? Int, (status == 0 || status == 200),
           let dataStr = resp["data"] as? String, !dataStr.isEmpty {
            return Self.buildFormattedQRCodeUrl(
                fromRawDaemonJson: dataStr,
                localIP: localIP,
                ssid: ssid,
                deviceId: fallbackDeviceId
            )
        }
        return Self.buildFormattedQRCodeUrl(
            fromRawDaemonJson: nil,
            localIP: localIP,
            ssid: ssid,
            deviceId: fallbackDeviceId
        )
    }

    public func getConnectedRemoteDevice(fallbackLocalIP: String = "192.168.31.1") async -> (device: OppoDevice, localIP: String)? {
        guard isDaemonAvailable else { return nil }
        let uri = buildIpcUri(path: "/get_remote_device", scope: 1, params: nil)
        guard let resp = try? await request(path: uri, timeoutMs: 2500),
              let status = resp["status"] as? Int, (status == 0 || status == 200),
              let dataStr = resp["data"] as? String,
              let data = dataStr.data(using: .utf8),
              let devJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let deviceId = (devJson["device_id"] as? String) ?? ""
        let deviceName = (devJson["device_name"] as? String) ?? "OPPO / 一加手机"
        let lanIpRaw = (devJson["lan_ip"] as? String) ?? ""
        let localIpRaw = (devJson["local_ip"] as? String) ?? ""
        let unmaskedLocalIp = Self.unmaskDaemonIP(localIpRaw.split(separator: ":").first.map(String.init) ?? "", localIP: fallbackLocalIP)
        let effectiveLocalIP = unmaskedLocalIp.isEmpty ? fallbackLocalIP : unmaskedLocalIp
        let unmaskedLan = Self.unmaskDaemonIP(lanIpRaw, localIP: effectiveLocalIP)
        let ipParts = unmaskedLan.split(separator: ":")
        let ip = ipParts.first.map(String.init) ?? unmaskedLan
        let port = ipParts.count > 1 ? (Int(ipParts[1]) ?? 10152) : 10152
        guard !ip.isEmpty, !deviceId.isEmpty else { return nil }
        let dev = OppoDevice(
            deviceId: deviceId,
            deviceName: deviceName,
            lanIP: ip,
            port: port,
            connectType: (devJson["connect_type"] as? Int) ?? 16,
            isPaired: true,
            isSameAccount: (devJson["is_same_account"] as? Bool) ?? false,
            discoverySource: .dspDaemon
        )
        return (dev, unmaskedLocalIp)
    }

    public func requestConnection(to device: OppoDevice) async throws -> [String: Any] {
        let address = device.lanIP.contains(":") ? device.lanIP : "\(device.lanIP):\(String(device.port))"
        let validDeviceId: String
        if device.deviceId.isEmpty || device.deviceId.hasPrefix("oppo-") {
            validDeviceId = LanSdpDiscovery.deterministicDeviceId(forIP: device.lanIP)
        } else {
            validDeviceId = device.deviceId
        }
        let primaryType = device.connectType == 0 ? 16 : device.connectType
        let payload: [String: Any] = [
            "connect_type": primaryType,
            "device_id": validDeviceId,
            "device_address": address,
            "is_same_account": device.isSameAccount,
            "device_type": 8
        ]
        let uri = buildIpcUri(path: "/request_connection", scope: 1, params: payload)
        return try await request(path: uri, timeoutMs: 5000)
    }

    public func acceptConnection(deviceId: String, connectType: Int, deviceAddress: String) async {
        let payload: [String: Any] = [
            "connect_type": connectType,
            "device_id": deviceId,
            "device_address": deviceAddress
        ]
        let uri = buildIpcUri(path: "/accept_connection", scope: 1, params: payload)
        _ = try? await request(path: uri, timeoutMs: 4000)
    }

    public func stopConnection(connectType: Int = 16) async throws -> [String: Any] {
        let uri = buildIpcUri(path: "/stop_connection", scope: 1, params: ["connect_type": connectType])
        return try await request(path: uri, timeoutMs: 3000)
    }

    // MARK: - MacChannelService Agent APIs (File Manager & OShare Handshake)

    public func createAgent() async {
        let payload: [String: Any] = [
            "app_name": "MacChannelService",
            "profile_id": "app:oshare.mac.agent",
            "role": 1,
            "service_profile_name": "app:oshare.mac.agent"
        ]
        let uri = buildIpcUri(path: "/create_agent", scope: 1, params: payload)
        _ = try? await request(path: uri, timeoutMs: 4000)
    }

    public func connectAgent(connectType: Int) async {
        let payload: [String: Any] = [
            "connect_type": connectType == 0 ? 16 : connectType
        ]
        let uri = buildIpcUri(path: "/connect_agent", scope: 1, params: payload)
        _ = try? await request(path: uri, timeoutMs: 4000)
    }

    public func disconnectAgent(connectType: Int) async {
        let payload: [String: Any] = [
            "connect_type": connectType == 0 ? 16 : connectType
        ]
        let uri = buildIpcUri(path: "/disconnect_agent", scope: 1, params: payload)
        _ = try? await request(path: uri, timeoutMs: 3000)
    }

    public func sendAgentMessage(deviceId: String, jsonObject: [String: Any]) async {
        guard !deviceId.isEmpty,
              let msgData = try? JSONSerialization.data(withJSONObject: jsonObject) else {
            return
        }
        let bodyObj: [String: Any] = [
            "app_name": "MacChannelService",
            "device_id": deviceId,
            "data": msgData.base64EncodedString()
        ]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: bodyObj) else { return }
        let uri = buildIpcUri(path: "/send_data", scope: 1, params: nil)
        _ = try? await request(path: uri, method: "POST", body: httpBody, timeoutMs: 5000)
    }

    // MARK: - DataBus Subscriptions (SMS Notification Sync, Incoming Call & Battery)

    public func registerDataBusApp() async throws -> [String: Any] {
        let uri = buildIpcUri(path: "/register_app", scope: 1, params: ["app_name": "O+Connect"])
        return try await request(path: uri, timeoutMs: 3000)
    }

    public func setupNotificationAndMacSubscriptions(appId: Int) async {
        self.registeredAppId = appId
        let macSub = buildIpcUri(path: "/create_subscribe", scope: 1, params: [
            "app_id": appId,
            "topic_name": "Oplus_MacConnect",
            "topic_tag": 0
        ])
        let macPub = buildIpcUri(path: "/create_publisher", scope: 1, params: [
            "app_id": appId,
            "topic_name": "Oplus_MacConnect",
            "topic_tag": 0
        ])
        let notifySub = buildIpcUri(path: "/create_subscribe", scope: 1, params: [
            "app_id": appId,
            "topic_name": "Oplus_HeySynergy_PcConnect_SyncNotification_Publisher",
            "topic_tag": 0
        ])
        let notifyPub = buildIpcUri(path: "/create_publisher", scope: 1, params: [
            "app_id": appId,
            "topic_name": "Oplus_HeySynergy_PcConnect_SyncNotification_Subscriber",
            "topic_tag": 0
        ])
        _ = try? await request(path: macSub)
        _ = try? await request(path: macPub)
        _ = try? await request(path: notifySub)
        _ = try? await request(path: notifyPub)

        await publishMessage(
            appId: appId,
            topicName: "Oplus_HeySynergy_PcConnect_SyncNotification_Subscriber",
            key: "HeySynergy_Notification_Add",
            value: ""
        )
        await publishMessage(
            appId: appId,
            topicName: "Oplus_HeySynergy_PcConnect_SyncNotification_Subscriber",
            key: "HeySynergy_Notification_Delete",
            value: ""
        )
        await publishMessage(
            appId: appId,
            topicName: "Oplus_HeySynergy_PcConnect_SyncNotification_Subscriber",
            key: "HeySynergy_Notification_Error",
            value: ""
        )

        // Announce PC capabilities & activate bidirectional cross-device clipboard sync (`crossdeviceClipboardVersion: 1200`)
        await sendClipboardSyncState(appId: appId, enabled: true, isFirstTime: true)
        await syncCastUnlockMode(appId: appId, mode: "auto")
    }

    public func sendClipboardSyncState(appId: Int? = nil, enabled: Bool = true, isFirstTime: Bool = false) async {
        let abilityDict: [String: Any] = [
            "PCVersion": "17.20.0",
            "CastAbility": "1000",
            "GameCastAbility": "1000",
            "Synergy_CastUnlock_Version": 2000,
            "crossdeviceClipboardVersion": "1200",
            "ScreenShareAbility": "0",
            "Notice_ClipBoard": enabled ? 1 : 0,
            "Notice_CrossDevice": 1,
            "Notice_MaterialFlow": 1,
            "ScreenShareArrange": 0,
            "Synergy_CastUnlock_Mode": "auto",
            "OSType": "macos",
            "OSVersion": "15.0"
        ]
        await publishMessage(appId: appId, topicName: "Oplus_MacConnect", key: "pcAbility", value: abilityDict)

        let stateDict: [String: Any] = [
            "crossdeviceClipboardVersion": "1200",
            "source": "macos",
            "state": enabled ? 1 : 0
        ]
        if let stateData = try? JSONSerialization.data(withJSONObject: stateDict),
           let stateStr = String(data: stateData, encoding: .utf8) {
            if isFirstTime {
                await publishMessage(
                    appId: appId,
                    topicName: "Oplus_MacConnect",
                    key: "clipboard_state_first_time",
                    value: stateStr
                )
            }
            await publishMessage(
                appId: appId,
                topicName: "Oplus_MacConnect",
                key: "clipboard_state_active",
                value: stateStr
            )
        }
    }

    /// Sends Mac clipboard text to the connected phone via `Oplus_MacConnect` (`key: "clipboard_data"`).
    /// Matches `clipboard::clipboard_common::common_json::JsonCommonData` schema (`crossdeviceClipboardVersion: "1200"`).
    public func sendClipboardToPhone(text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let payload = Self.buildClipboardDataPayload(text: text)
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: data, encoding: .utf8) else {
            return
        }
        await publishMessage(topicName: "Oplus_MacConnect", key: "clipboard_data", value: jsonString)
    }

    public static func buildClipboardDataPayload(text: String) -> [String: Any] {
        let timestampMs = Int64(Date().timeIntervalSince1970 * 1000)
        return [
            "crossdeviceClipboardVersion": "1200",
            "timestamp": timestampMs,
            "source": "macos",
            "data": [
                "text": [
                    "content": text,
                    "encoding": "UTF-8"
                ],
                "html": NSNull(),
                "htmlData": NSNull(),
                "image": NSNull(),
                "files": NSNull()
            ]
        ]
    }

    /// Extracts plain text content from an incoming `clipboard_data` payload sent by the phone.
    public static func extractClipboardText(from rawValue: Any) -> String? {
        let dict: [String: Any]?
        if let d = rawValue as? [String: Any] {
            dict = d
        } else if let str = rawValue as? String,
                  let data = str.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = parsed
        } else {
            dict = nil
        }
        guard let dict else { return nil }

        // Ignore self-originated macOS clipboard payloads
        if let source = (dict["source"] as? String)?.lowercased(), source == "macos" || source == "mac" {
            return nil
        }

        if let dataObj = dict["data"] as? [String: Any] {
            if let textObj = dataObj["text"] as? [String: Any],
               let content = textObj["content"] as? String,
               !content.isEmpty {
                return content
            }
            if let textStr = dataObj["text"] as? String, !textStr.isEmpty {
                return textStr
            }
        }
        if let textObj = dict["text"] as? [String: Any],
           let content = textObj["content"] as? String,
           !content.isEmpty {
            return content
        }
        if let directContent = dict["content"] as? String, !directContent.isEmpty {
            return directContent
        }
        return nil
    }

    public func publishMessage(appId: Int? = nil, topicName: String, key: String, value: Any) async {
        let resolvedAppId = appId ?? self.registeredAppId ?? 12
        let msgData: [String: Any] = ["key": key, "value": value]
        guard let msgJsonData = try? JSONSerialization.data(withJSONObject: msgData),
              let msgJsonStr = String(data: msgJsonData, encoding: .utf8) else { return }
        let uri = buildIpcUri(path: "/publish_message", scope: 1, params: [
            "app_id": resolvedAppId,
            "topic_name": topicName,
            "topic_tag": 0,
            "msg": msgJsonStr
        ])
        _ = try? await request(path: uri)
    }

    /// Syncs screen cast unlock mode (`Synergy_CastUnlock_Version` & `Synergy_CastUnlock_Mode`) on `Oplus_MacConnect`.
    public func syncCastUnlockMode(appId: Int? = nil, mode: String = "auto") async {
        await publishMessage(appId: appId, topicName: "Oplus_MacConnect", key: "Synergy_CastUnlock_Version", value: "2000")
        await publishMessage(appId: appId, topicName: "Oplus_MacConnect", key: "Synergy_CastUnlock_Mode", value: mode)
    }

    /// Sends one-click call hangup (`actionType = 1`) to the phone via `Oplus_MacConnect` (`incallui_reply`).
    public func hangupIncomingCall(callId: String, phoneNumber: String) async {
        let replyValue: [String: Any] = [
            "id": callId,
            "number": phoneNumber,
            "actionType": 1,
            "msg": ""
        ]
        await publishMessage(topicName: "Oplus_MacConnect", key: "incallui_reply", value: replyValue)
    }

    /// Rejects an incoming call and sends a quick SMS reply (`actionType = 2`) via `Oplus_MacConnect` (`incallui_reply`).
    public func replyIncomingCallWithSMS(callId: String, phoneNumber: String, message: String) async {
        let replyValue: [String: Any] = [
            "id": callId,
            "number": phoneNumber,
            "actionType": 2,
            "msg": message
        ]
        await publishMessage(topicName: "Oplus_MacConnect", key: "incallui_reply", value: replyValue)
    }

    public func buildRemoteListPayload(
        remotePath: String,
        bucketKey: String? = nil,
        pageNo: Int = 1,
        pageSize: Int = 500,
        includeThumbnails: Bool = false
    ) -> [String: Any] {
        let sessionId = UUID().uuidString
        let hasBucket = (bucketKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        let api = hasBucket ? "album.set" : "file.path.list"
        let body: [String: Any]
        if let bucket = bucketKey, hasBucket {
            let normalizedBucket = bucket.hasPrefix("/storage/emulated/0/")
                ? String(bucket.dropFirst("/storage/emulated/0/".count))
                : bucket
            body = [
                "pageNo": pageNo,
                "pageSize": pageSize,
                "pageName": 1,
                "sortOrder": 0,
                "bucketKey": normalizedBucket,
                "filePath": "",
                "needThumbnail": includeThumbnails
            ]
        } else {
            body = [
                "pageNo": pageNo,
                "pageSize": pageSize,
                "pageName": "sn",
                "sortOrder": 0,
                "filePath": remotePath,
                "needThumbnail": includeThumbnails
            ]
        }
        return [
            "api": api,
            "sessionId": sessionId,
            "header": [
                "clientVersion": "1.0.0",
                "apilevel": "1"
            ],
            "body": body
        ]
    }

    public func buildFileRootPayload() -> [String: Any] {
        [
            "api": "file.root",
            "sessionId": UUID().uuidString,
            "header": [
                "clientVersion": "1.0.0",
                "apilevel": "1"
            ],
            "body": [:] as [String: Any]
        ]
    }

    public func buildCategoryQueryPayload(
        categoryId: Int,
        sessionId: String = UUID().uuidString,
        pageNo: Int = 1,
        pageSize: Int = 5000
    ) -> [String: Any] {
        [
            "api": "file.category.query",
            "sessionId": sessionId,
            "header": [
                "clientVersion": "1.0.0",
                "apilevel": "1"
            ],
            "body": [
                "pageNo": pageNo,
                "pageSize": pageSize,
                "sortOrder": 0,
                "categoryId": categoryId,
                "needThumbnail": false
            ]
        ]
    }

    public func buildFileListSearchPayload(
        filePaths: [String],
        sessionId: String = "STORAGE_SCAN_\(UUID().uuidString)"
    ) -> [String: Any] {
        [
            "api": "file.list.search",
            "sessionId": sessionId,
            "header": [
                "clientVersion": "1.0.0",
                "apilevel": "1"
            ],
            "body": [
                "filePath": filePaths,
                "folder": false,
                "transfer": true
            ]
        ]
    }

    /// Builds `file.operate` (`operateType = 5`) payload to delete files/folders on the phone.
    public func buildDeleteFilesPayload(filePaths: [String]) -> [String: Any] {
        let sourceInfo: [[String: Any]] = filePaths.map { ["data": $0] }
        return [
            "api": "file.operate",
            "sessionId": UUID().uuidString,
            "header": [
                "clientVersion": "1.0.0",
                "apilevel": "1"
            ],
            "body": [
                "operateType": 5,
                "sourceFileInfo": sourceInfo,
                "option": 2
            ]
        ]
    }

    /// Builds `file.operate` (`operateType = 1`) payload to create a folder on the phone if needed.
    public func buildCreateFolderPayload(parentPath: String, folderName: String) -> [String: Any] {
        let fullPath = parentPath.hasSuffix("/") ? "\(parentPath)\(folderName)" : "\(parentPath)/\(folderName)"
        return [
            "api": "file.operate",
            "sessionId": UUID().uuidString,
            "header": [
                "clientVersion": "1.0.0",
                "apilevel": "1"
            ],
            "body": [
                "operateType": 1,
                "targetFolderPath": parentPath,
                "folderName": folderName,
                "filePath": fullPath,
                "sourceFileInfo": [["data": fullPath, "displayName": folderName]],
                "option": 2
            ]
        ]
    }

    /// Builds `file.operate` (`operateType = 4`) payload to move files on the phone into `targetFolderPath`.
    public func buildMoveFilesPayload(
        sourceItems: [(path: String, name: String)],
        targetFolderPath: String
    ) -> [String: Any] {
        let sourceInfo: [[String: Any]] = sourceItems.map {
            [
                "data": $0.path,
                "displayName": $0.name
            ]
        }
        return [
            "api": "file.operate",
            "sessionId": UUID().uuidString,
            "header": [
                "clientVersion": "1.0.0",
                "apilevel": "1"
            ],
            "body": [
                "operateType": 4,
                "targetFolderPath": targetFolderPath,
                "sourceFileInfo": sourceInfo,
                "option": 2
            ]
        ]
    }
}
