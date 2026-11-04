import Foundation
import AppKit
import Darwin

/// Manages the official OPPO Screen Mirroring runtime (`手机投屏.app` / `Odmf.framework`)
/// over ColorDrop's isolated Unix Domain Sockets (`/tmp/oppolite-castc` & `/tmp/oppolite-caste`).
/// Enables full interactive mouse/trackpad/keyboard control of the connected phone from Mac.
public final class ScreenMirrorService: @unchecked Sendable {
    public static let shared = ScreenMirrorService()

    public let castHttpSocketPath = "/tmp/oppolite-castc"
    public let castEventSocketPath = "/tmp/oppolite-caste"
    public let castBundleIdentifier = "com.oplus.Window"

    private let lock = NSLock()
    private var castProcess: Process?
    private var isSubscribingEvents = false
    private var isCastServiceReady = false
    private var isLaunchingCastProcess = false
    private var _isMirroringActive = false

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public var isMirroringActive: Bool {
        withLock { _isMirroringActive }
    }

    public var onMirrorStateChanged: ((Bool, String) -> Void)?
    public var onUnlockModeChanged: ((String) -> Void)?

    private init() {
        prepareLogDirectories()
    }

    private func prepareLogDirectories() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let dirs = [
            "/tmp/oppolite-oppodat",
            home + "/Library/Logs/devicespace/odmf_log/odmf_audio",
            home + "/Library/Logs/PcCastLog",
            "/tmp/oppolite-oppodat/Library/Logs/devicespace/odmf_log/odmf_audio",
            "/tmp/oppolite-oppodat/Library/Logs/PcCastLog"
        ]
        for dir in dirs {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }

    /// Locates the bundled `手机投屏.app` across all deployment environments.
    public func locateCastAppBundlePath() -> String? {
        let execDir = URL(fileURLWithPath: CommandLine.arguments.first ?? Bundle.main.executablePath ?? "")
            .deletingLastPathComponent()
        let inferredResources = execDir.deletingLastPathComponent().appendingPathComponent("Resources").path

        let candidates = [
            Bundle.main.bundlePath + "/Contents/Resources/Vendor/手机投屏.app",
            Bundle.main.bundlePath + "/Contents/Resources/app_process/手机投屏.app",
            inferredResources + "/Vendor/手机投屏.app",
            inferredResources + "/app_process/手机投屏.app",
            FileManager.default.currentDirectoryPath + "/Vendor/手机投屏.app",
            "/Applications/ColorDrop.app/Contents/Resources/Vendor/手机投屏.app"
        ]
        return candidates.first { path in
            FileManager.default.isExecutableFile(atPath: path + "/Contents/MacOS/手机投屏")
        }
    }

    public var isCastSocketAvailable: Bool {
        guard FileManager.default.fileExists(atPath: castHttpSocketPath) else { return false }
        return canConnectUnixSocket(path: castHttpSocketPath)
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

    // MARK: - Ensure `手机投屏.app` Process Running & Subscribed

    public func ensureCastProcessRunning() async -> Bool {
        prepareLogDirectories()

        if isCastSocketAvailable {
            startCastEventSubscriptionIfNeeded()
            return true
        }

        guard let appBundlePath = locateCastAppBundlePath() else {
            return false
        }
        let execPath = appBundlePath + "/Contents/MacOS/手机投屏"

        let alreadyLaunching = withLock { () -> Bool in
            if isLaunchingCastProcess { return true }
            isLaunchingCastProcess = true
            isCastServiceReady = false
            return false
        }
        if alreadyLaunching {
            for _ in 0..<25 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if isCastSocketAvailable { return true }
            }
            return isCastSocketAvailable
        }

        defer {
            withLock { isLaunchingCastProcess = false }
        }

        unlink(castHttpSocketPath)
        unlink(castEventSocketPath)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: execPath)
        proc.arguments = ["1", "0"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { [weak self] _ in
            guard let self else { return }
            let wasActive = self.withLock { () -> Bool in
                self.isCastServiceReady = false
                let prev = self._isMirroringActive
                self._isMirroringActive = false
                return prev
            }
            if wasActive {
                self.onMirrorStateChanged?(false, "手机镜像窗口已关闭")
            }
        }

        do {
            try proc.run()
            withLock { castProcess = proc }
        } catch {
            return false
        }

        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if isCastSocketAvailable {
                startCastEventSubscriptionIfNeeded()
                break
            }
        }

        for _ in 0..<15 {
            let ready = withLock { isCastServiceReady }
            if ready { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        return isCastSocketAvailable
    }

    // MARK: - Start / Stop Screen Mirroring

    public static func buildStartMirrorParams(
        device: OppoDevice,
        localIP: String,
        mainWindowBounds: CGRect = CGRect(x: 180, y: 140, width: 900, height: 580),
        mirageFrom: Int = 1
    ) -> [String: Any] {
        var phoneWidth = 1080
        var phoneHeight = 2400
        if let res = device.screenResolution, !res.isEmpty {
            let parts = res.replacingOccurrences(of: "×", with: "*")
                .replacingOccurrences(of: "x", with: "*")
                .split(separator: "*")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2, parts[0] > 0, parts[1] > 0 {
                phoneWidth = parts[0]
                phoneHeight = parts[1]
            }
        }

        let defaultShortcuts: [String: Any] = [
            "backShortcutKey": "Cmd+B",
            "homeShortcutKey": "Cmd+H",
            "recentTasksShortcutKey": "Cmd+T",
            "windowVisibilityShortcutKey": "Ctrl+Alt+Z",
            "windowEnlargeShortcutKey": "Cmd+Up",
            "windowShrinkShortcutKey": "Cmd+Down"
        ]

        return [
            "remote_device_type": 1,
            "local_device_type": 0,
            "component_name": "",
            "remote_device_ip": device.lanIP,
            "is_same_account": device.isSameAccount,
            "version": "17.20.0",
            "deviceId": device.deviceId,
            "phone_name": device.deviceName,
            "local_ip": localIP,
            "image_quality": "auto",
            "welt_auto_hide": true,
            "show_front_windows": false,
            "current_language": "zh-CN",
            "audio_output_source": 0,
            "main_window_bounds": [
                "x": Int(mainWindowBounds.origin.x),
                "y": Int(mainWindowBounds.origin.y),
                "width": max(760, Int(mainWindowBounds.size.width)),
                "height": max(480, Int(mainWindowBounds.size.height)),
                "is_focus": true
            ],
            "application_name": "",
            "cast_mode": 0,
            "mirage_from": mirageFrom,
            "shortcut_key": defaultShortcuts,
            "phone_width": phoneWidth,
            "phone_height": phoneHeight,
            "phone_model": device.phoneModel ?? device.deviceName
        ]
    }

    public func startScreenMirroring(
        device: OppoDevice,
        localIP: String,
        mainWindowBounds: CGRect,
        mirageFrom: Int = 1
    ) async -> Bool {
        focusCastWindowIfRunning()

        let ready = await ensureCastProcessRunning()
        guard ready else {
            onMirrorStateChanged?(false, "无法启动手机镜像服务，请检查组件完整性")
            return false
        }

        let params = Self.buildStartMirrorParams(
            device: device,
            localIP: localIP,
            mainWindowBounds: mainWindowBounds,
            mirageFrom: mirageFrom
        )
        guard let jsonData = try? JSONSerialization.data(withJSONObject: params) else {
            return false
        }
        let b64 = jsonData.base64EncodedString()
        let path = "/start_mirror?scope=1&params=\(b64)"

        do {
            let resp = try performCastHTTPRequest(path: path, timeoutMs: 5000)
            let status = (resp["status"] as? Int) ?? 200
            if status == 200 || status == 0 {
                withLock { _isMirroringActive = true }
                focusCastWindowIfRunning()
                onMirrorStateChanged?(true, "已发起 \(device.deviceName) 手机镜像，可在手机端确认或直接用鼠标操控")
                return true
            }
        } catch {}

        return false
    }

    public func stopScreenMirroring() async {
        guard isCastSocketAvailable else {
            withLock { _isMirroringActive = false }
            onMirrorStateChanged?(false, "手机镜像已关闭")
            return
        }

        if let data = try? JSONSerialization.data(withJSONObject: ["component_name": ""]) {
            let path = "/stop_mirror?scope=1&params=\(data.base64EncodedString())"
            _ = try? performCastHTTPRequest(path: path, timeoutMs: 2500)
        }
        withLock { _isMirroringActive = false }
        onMirrorStateChanged?(false, "手机镜像已关闭")
    }

    public func stopAllCastOnDisconnect() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            if self.isCastSocketAvailable {
                let emptyB64 = Data("\"\"".utf8).base64EncodedString()
                _ = try? self.performCastHTTPRequest(path: "/stop_all_cast?scope=1&params=\(emptyB64)", timeoutMs: 2000)
            }
            self.lock.lock()
            self._isMirroringActive = false
            self.lock.unlock()
        }
    }

    public func focusCastWindowIfRunning() {
        DispatchQueue.main.async {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: self.castBundleIdentifier)
            if let app = running.first {
                app.activate(options: [.activateIgnoringOtherApps])
            }
        }
    }

    // MARK: - Cast Event Stream (`/tmp/oppolite-caste` -> `cast_callback`)

    private func startCastEventSubscriptionIfNeeded() {
        lock.lock()
        if isSubscribingEvents || !FileManager.default.fileExists(atPath: castEventSocketPath) {
            lock.unlock()
            return
        }
        isSubscribingEvents = true
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.isSubscribingEvents = false
                self.lock.unlock()
            }

            while FileManager.default.fileExists(atPath: self.castEventSocketPath) {
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else {
                    Thread.sleep(forTimeInterval: 1.0)
                    continue
                }

                var addr = sockaddr_un()
                addr.sun_family = sa_family_t(AF_UNIX)
                let pathBytes = self.castEventSocketPath.utf8CString
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
                    Thread.sleep(forTimeInterval: 0.5)
                    continue
                }

                let handshake = "cast_callback\n"
                _ = handshake.withCString { cstr in
                    Darwin.send(fd, cstr, strlen(cstr), 0)
                }

                var buffer = [UInt8](repeating: 0, count: 32768)
                var pending = Data()
                while true {
                    let n = Darwin.recv(fd, &buffer, buffer.count, 0)
                    if n <= 0 { break }
                    pending.append(buffer, count: n)
                    while let nl = pending.firstIndex(of: UInt8(ascii: "\n")) {
                        let lineData = pending.subdata(in: 0..<nl)
                        pending.removeSubrange(0...nl)
                        if let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                            self.handleCastCallbackEvent(obj)
                        }
                    }
                }
                close(fd)
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }

    private func handleCastCallbackEvent(_ dict: [String: Any]) {
        let event = (dict["event"] as? String) ?? ""
        switch event {
        case "cast_service_enable":
            lock.lock()
            isCastServiceReady = true
            lock.unlock()
        case "cast_service_unable":
            lock.lock()
            isCastServiceReady = false
            lock.unlock()
        case "onCastSuccess":
            lock.lock()
            _isMirroringActive = true
            lock.unlock()
            focusCastWindowIfRunning()
            onMirrorStateChanged?(true, "手机镜像已连接 · 可使用 Mac 鼠标与键盘操控手机")
        case "onCastEnd":
            lock.lock()
            _isMirroringActive = false
            lock.unlock()
            onMirrorStateChanged?(false, "手机镜像已结束")
        case "onCastFailed":
            lock.lock()
            _isMirroringActive = false
            lock.unlock()
            onMirrorStateChanged?(false, "手机镜像连接失败，请在手机端确认投屏权限后重试")
        case "firstUnlockToast":
            if let msgStr = dict["msg"] as? String,
               let msgData = msgStr.data(using: .utf8),
               let msgJson = try? JSONSerialization.jsonObject(with: msgData) as? [String: Any] {
                let allow = (msgJson["isAllowUnlock"] as? String) == "allow"
                onUnlockModeChanged?(allow ? "auto" : "every")
            }
        default:
            break
        }
    }

    // MARK: - HTTP Request over `/tmp/oppolite-castc`

    private func performCastHTTPRequest(path: String, timeoutMs: Int) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "ScreenMirrorService", code: Int(errno), userInfo: nil)
        }
        defer { close(fd) }

        var tv = timeval(tv_sec: timeoutMs / 1000, tv_usec: Int32((timeoutMs % 1000) * 1000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = castHttpSocketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw NSError(domain: "ScreenMirrorService", code: -1, userInfo: nil)
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
            throw NSError(domain: "ScreenMirrorService", code: Int(errno), userInfo: nil)
        }

        let header = "GET \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        let requestData = Data(header.utf8)
        try requestData.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var sent = 0
            while sent < rawBuf.count {
                let n = Darwin.send(fd, base.advanced(by: sent), rawBuf.count - sent, 0)
                if n <= 0 {
                    throw NSError(domain: "ScreenMirrorService", code: Int(errno), userInfo: nil)
                }
                sent += n
            }
        }

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 32768)
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
}
