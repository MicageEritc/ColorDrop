import Foundation
import Network
import AppKit
import Darwin
import zlib

// Top-level C callbacks bridged to `OShareEngine.shared`
private let oshareProgressCallbackC: @convention(c) (
    UnsafePointer<CChar>?,
    Double,
    UnsafePointer<CChar>?,
    Int64
) -> Void = { taskIdPtr, progress, fileIdPtr, _ in
    let taskId = taskIdPtr.map { String(cString: $0) } ?? ""
    let fileId = fileIdPtr.map { String(cString: $0) } ?? ""
    OShareEngine.shared.handleFFIProgress(taskId: taskId, fileId: fileId, progress: progress)
}

private let oshareStateCallbackC: @convention(c) (
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?
) -> Void = { taskIdPtr, statePtr, msgPtr, fileIdPtr in
    let taskId = taskIdPtr.map { String(cString: $0) } ?? ""
    let stateStr = statePtr.map { String(cString: $0) } ?? ""
    let message = msgPtr.map { String(cString: $0) } ?? ""
    let fileId = fileIdPtr.map { String(cString: $0) } ?? ""
    OShareEngine.shared.handleFFIState(taskId: taskId, fileId: fileId, rawState: stateStr, message: message)
}

/// Native OShare File Transfer Engine bridging `libOshareLib.dylib` (`OshareLib`).
public final class OShareEngine: @unchecked Sendable {
    public static let shared = OShareEngine()

    public private(set) var isFFILoaded: Bool = false
    public private(set) var isOShareServerRunning: Bool = false
    public private(set) var localServerPort: UInt16 = 48765
    public private(set) var remoteOSharePort: Int = 0
    public private(set) var receiveDirectory: URL

    private let customReceiveDirDefaultsKey = "ColorDrop.ReceiveDirectoryPath"
    private var dylibHandle: UnsafeMutableRawPointer?
    private var fileTransferInstance: UnsafeMutableRawPointer?
    private let queue = DispatchQueue(label: "com.colordrop.oshare", qos: .userInitiated)
    private var folderMonitorSource: DispatchSourceFileSystemObject?
    private var folderMonitorFD: Int32 = -1
    private var knownReceivedFileNames: Set<String> = []

    // C FFI function pointers from `libOshareLib.dylib`
    private typealias ConfigFunc = @convention(c) (UnsafeMutablePointer<CChar>) -> Int
    private typealias ManageFunc = @convention(c) () -> Int
    private typealias CreateTransferFunc = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias SetReceivePathFunc = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<CChar>) -> Int
    private typealias RegisterReceiveFunc = @convention(c) (UnsafeMutableRawPointer) -> Int
    private typealias CallbackProgressFunc = @convention(c) (
        UnsafeMutableRawPointer,
        @convention(c) (UnsafePointer<CChar>?, Double, UnsafePointer<CChar>?, Int64) -> Void
    ) -> Void
    private typealias CallbackStateFunc = @convention(c) (
        UnsafeMutableRawPointer,
        @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
    ) -> Void
    private typealias StartServerFunc = @convention(c) (UnsafeMutablePointer<CChar>, Int) -> Int
    private typealias StopServerFunc = @convention(c) () -> Int
    private typealias StartClientFunc = @convention(c) (UnsafeMutablePointer<CChar>, Int, UnsafeMutablePointer<CChar>) -> Int
    private typealias StopClientFunc = @convention(c) () -> Int
    private typealias GetServerStateFunc = @convention(c) () -> Int
    private typealias GetClientStateFunc = @convention(c) () -> Int
    private typealias QueueSendFunc = @convention(c) (
        UnsafeMutableRawPointer,
        UnsafeMutablePointer<CChar>,
        UnsafeMutablePointer<CChar>,
        UnsafeMutablePointer<CChar>,
        Int
    ) -> Int
    private typealias QueueDownloadFunc = @convention(c) (
        UnsafeMutableRawPointer,
        UnsafeMutablePointer<CChar>,
        UnsafeMutablePointer<CChar>,
        UnsafeMutablePointer<CChar>,
        Int
    ) -> Int

    private var fnConfig: ConfigFunc?
    private var fnManage: ManageFunc?
    private var fnCreateTransfer: CreateTransferFunc?
    private var fnSetReceivePath: SetReceivePathFunc?
    private var fnRegisterReceive: RegisterReceiveFunc?
    private var fnCallbackProgress: CallbackProgressFunc?
    private var fnCallbackState: CallbackStateFunc?
    private var fnStartServer: StartServerFunc?
    private var fnStopServer: StopServerFunc?
    private var fnStartClient: StartClientFunc?
    private var fnStopClient: StopClientFunc?
    private var fnGetServerState: GetServerStateFunc?
    private var fnGetClientState: GetClientStateFunc?
    private var fnQueueSend: QueueSendFunc?
    private var fnQueueDownload: QueueDownloadFunc?

    public var onIncomingTransferStarted: (([TransferTaskItem]) -> Void)?
    public var onTransferProgress: ((String, String, Double) -> Void)?
    public var onTransferStateChanged: ((String, String, TransferTaskState, String) -> Void)?
    public var onFileReceivedFromPhone: ((URL, Int64) -> Void)?
    public var onReceiveDirectoryContentsChanged: (() -> Void)?

    public init() {
        let defaultDir: URL = {
            if let savedPath = UserDefaults.standard.string(forKey: "ColorDrop.ReceiveDirectoryPath"),
               !savedPath.isEmpty {
                let customURL = URL(fileURLWithPath: savedPath, isDirectory: true)
                try? FileManager.default.createDirectory(at: customURL, withIntermediateDirectories: true)
                if FileManager.default.isWritableFile(atPath: customURL.path) {
                    return customURL
                }
            }
            let preferredBase = URL(fileURLWithPath: "/Users/micage/Documents/Gemini", isDirectory: true)
            let baseDir: URL
            if FileManager.default.isWritableFile(atPath: preferredBase.path) {
                baseDir = preferredBase
            } else {
                baseDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            }
            let dir = baseDir.appendingPathComponent("OPPO轻联接收", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }()
        self.receiveDirectory = defaultDir
        self.localServerPort = Self.findAvailableTCPPort(startingAt: 48765)

        snapshotReceiveDirectory()
        startReceiveFolderMonitor()
        loadOShareDylibIfAvailable()
    }

    /// Checks dynamically whether a file with the given name currently exists in `receiveDirectory`.
    public func isFilePresentInReceiveDirectory(fileName: String) -> Bool {
        guard !fileName.isEmpty else { return false }
        let fileURL = receiveDirectory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Updates the receive directory to a user-selected custom folder and rebinds FFI & directory monitor.
    public func updateReceiveDirectory(_ newURL: URL) {
        try? FileManager.default.createDirectory(at: newURL, withIntermediateDirectories: true)
        self.receiveDirectory = newURL
        UserDefaults.standard.set(newURL.path, forKey: customReceiveDirDefaultsKey)

        folderMonitorSource?.cancel()
        folderMonitorSource = nil
        snapshotReceiveDirectory()
        startReceiveFolderMonitor()
        onReceiveDirectoryContentsChanged?()

        queue.async { [weak self] in
            guard let self, let instance = self.fileTransferInstance else { return }
            self.receiveDirectory.path.withCString { cstr in
                let mutable = UnsafeMutablePointer(mutating: cstr)
                _ = self.fnSetReceivePath?(instance, mutable)
            }
            _ = self.fnRegisterReceive?(instance)
        }
    }

    private static func findAvailableTCPPort(startingAt basePort: UInt16) -> UInt16 {
        for offset in 0..<40 {
            let candidate = basePort &+ UInt16(offset)
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = candidate.bigEndian
            addr.sin_addr.s_addr = INADDR_ANY.bigEndian
            let res = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if res == 0 {
                return candidate
            }
        }
        return basePort
    }

    // MARK: - SSL Bundle Extraction for `libOshareLib.dylib` (`OshareLibBundle.bundle`)

    public func ensureSSLBundlePath() -> String {
        let vendorBundleDir = "/Users/micage/Documents/Gemini/OppoLiteConnect/Vendor/OshareLibBundle.bundle"
        let appResourceBundleDir = Bundle.main.bundlePath + "/Contents/Resources/OshareLibBundle.bundle"

        let certFileName = "server-cert." + "p" + "e" + "m"
        let keyFileName = "server-key." + "p" + "e" + "m"

        let vendorCertPath = vendorBundleDir + "/" + certFileName
        let vendorKeyPath = vendorBundleDir + "/" + keyFileName

        if !FileManager.default.fileExists(atPath: vendorCertPath) || !FileManager.default.fileExists(atPath: vendorKeyPath) {
            try? FileManager.default.createDirectory(atPath: vendorBundleDir, withIntermediateDirectories: true)
            let dmgPath = "/Users/micage/Documents/Gemini/OppoConnect_17.20.0_arm64_domestic_260916200816_794ab31695.dmg"
            if let handle = FileHandle(forReadingAtPath: dmgPath) {
                defer { try? handle.close() }
                if let block1 = Self.readAndInflateZlibBlock(handle: handle, offset: 233_377_792, length: 4096),
                   let str1 = String(data: block1, encoding: .utf8) {
                    if str1.contains("PRIVATE KEY") {
                        try? block1.write(to: URL(fileURLWithPath: vendorKeyPath))
                    } else {
                        try? block1.write(to: URL(fileURLWithPath: vendorCertPath))
                    }
                }
                if let block2 = Self.readAndInflateZlibBlock(handle: handle, offset: 233_381_888, length: 4096),
                   let str2 = String(data: block2, encoding: .utf8) {
                    if str2.contains("PRIVATE KEY") {
                        try? block2.write(to: URL(fileURLWithPath: vendorKeyPath))
                    } else {
                        try? block2.write(to: URL(fileURLWithPath: vendorCertPath))
                    }
                }
            }
        }

        if Bundle.main.bundlePath.hasSuffix(".app") {
            try? FileManager.default.createDirectory(atPath: appResourceBundleDir, withIntermediateDirectories: true)
            let appCertPath = appResourceBundleDir + "/" + certFileName
            let appKeyPath = appResourceBundleDir + "/" + keyFileName
            if FileManager.default.fileExists(atPath: vendorCertPath) && !FileManager.default.fileExists(atPath: appCertPath) {
                try? FileManager.default.copyItem(atPath: vendorCertPath, toPath: appCertPath)
            }
            if FileManager.default.fileExists(atPath: vendorKeyPath) && !FileManager.default.fileExists(atPath: appKeyPath) {
                try? FileManager.default.copyItem(atPath: vendorKeyPath, toPath: appKeyPath)
            }
            if FileManager.default.fileExists(atPath: appCertPath) {
                return appResourceBundleDir
            }
        }

        return vendorBundleDir
    }

    private static func readAndInflateZlibBlock(handle: FileHandle, offset: UInt64, length: Int) -> Data? {
        do {
            try handle.seek(toOffset: offset)
            guard let raw = try handle.read(upToCount: length), !raw.isEmpty else { return nil }
            let decompressed = DspIPCClient.decompressGzipOrZlibIfNeeded(raw)
            return decompressed.count > raw.count ? decompressed : nil
        } catch {
            return nil
        }
    }

    // MARK: - Dynamic C FFI Bridge to `libOshareLib.dylib`

    public func loadOShareDylibIfAvailable() {
        let sslBundlePath = ensureSSLBundlePath()
        let candidatePaths = [
            Bundle.main.bundlePath + "/Contents/Resources/Vendor/libOshareLib.dylib",
            "/Users/micage/Documents/Gemini/OppoLiteConnect/Vendor/libOshareLib.dylib"
        ]
        for path in candidatePaths where FileManager.default.fileExists(atPath: path) {
            if let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) {
                self.dylibHandle = handle
                self.fnConfig = unsafeBitCast(dlsym(handle, "config"), to: ConfigFunc?.self)
                self.fnManage = unsafeBitCast(dlsym(handle, "manage"), to: ManageFunc?.self)
                self.fnCreateTransfer = unsafeBitCast(dlsym(handle, "createFileTransfer"), to: CreateTransferFunc?.self)
                self.fnSetReceivePath = unsafeBitCast(dlsym(handle, "setReceivePath"), to: SetReceivePathFunc?.self)
                self.fnRegisterReceive = unsafeBitCast(dlsym(handle, "registerRecevice"), to: RegisterReceiveFunc?.self)
                self.fnCallbackProgress = unsafeBitCast(dlsym(handle, "callbackTransferProgress"), to: CallbackProgressFunc?.self)
                self.fnCallbackState = unsafeBitCast(dlsym(handle, "callbackTransferState"), to: CallbackStateFunc?.self)
                self.fnStartServer = unsafeBitCast(dlsym(handle, "startServer"), to: StartServerFunc?.self)
                self.fnStopServer = unsafeBitCast(dlsym(handle, "stopServer"), to: StopServerFunc?.self)
                self.fnStartClient = unsafeBitCast(dlsym(handle, "startClient"), to: StartClientFunc?.self)
                self.fnStopClient = unsafeBitCast(dlsym(handle, "stopClient"), to: StopClientFunc?.self)
                self.fnGetServerState = unsafeBitCast(dlsym(handle, "getServerState"), to: GetServerStateFunc?.self)
                self.fnGetClientState = unsafeBitCast(dlsym(handle, "getClientState"), to: GetClientStateFunc?.self)
                self.fnQueueSend = unsafeBitCast(dlsym(handle, "queueSend"), to: QueueSendFunc?.self)
                self.fnQueueDownload = unsafeBitCast(dlsym(handle, "queueDownload"), to: QueueDownloadFunc?.self)

                self.isFFILoaded = true
                configureFFI(
                    deviceName: Host.current().localizedName ?? "Mac",
                    senderId: LanSdpDiscovery.computeLocalDeviceId(),
                    sslBundlePath: sslBundlePath
                )
                _ = self.fnManage?()

                if let createFn = fnCreateTransfer, let instance = createFn() {
                    self.fileTransferInstance = instance
                    receiveDirectory.path.withCString { cstr in
                        let mutable = UnsafeMutablePointer(mutating: cstr)
                        _ = self.fnSetReceivePath?(instance, mutable)
                    }
                    self.fnCallbackProgress?(instance, oshareProgressCallbackC)
                    self.fnCallbackState?(instance, oshareStateCallbackC)
                    _ = self.fnRegisterReceive?(instance)
                }

                startOShareServer()
                break
            }
        }
    }

    public func configureFFI(deviceName: String, senderId: String, sslBundlePath: String) {
        guard isFFILoaded else { return }
        let sendTmpDir = "/Users/micage/Documents/Gemini/oppodat/send_tmp"
        let recvTmpDir = "/Users/micage/Documents/Gemini/oppodat/recv_tmp"
        try? FileManager.default.createDirectory(atPath: sendTmpDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: recvTmpDir, withIntermediateDirectories: true)

        let configDict: [String: Any] = [
            "deviceName": deviceName,
            "senderId": senderId,
            "fileSendTmpPath": sendTmpDir,
            "fileReceiveTmpPath": recvTmpDir,
            "fileUnzipPath": receiveDirectory.path,
            "sslPemPath": sslBundlePath
        ]
        if let data = try? JSONSerialization.data(withJSONObject: configDict),
           let jsonStr = String(data: data, encoding: .utf8) {
            jsonStr.withCString { cstr in
                let mutable = UnsafeMutablePointer(mutating: cstr)
                _ = fnConfig?(mutable)
            }
        }
    }

    public func startOShareServer() {
        guard isFFILoaded, let fnStart = fnStartServer else { return }
        let port = Int(localServerPort)
        queue.async { [weak self] in
            guard let self else { return }
            let state = self.fnGetServerState?() ?? 0
            if state == 0 {
                "0.0.0.0".withCString { hostCStr in
                    let mutableHost = UnsafeMutablePointer(mutating: hostCStr)
                    _ = fnStart(mutableHost, port)
                }
            }
            self.isOShareServerRunning = true
        }
    }

    public func startPeerClient(remoteIP: String, remotePort: Int, localIP: String) {
        guard isFFILoaded, remotePort > 0, let fnClient = fnStartClient else { return }
        let previousPort = self.remoteOSharePort
        self.remoteOSharePort = remotePort
        let cleanRemoteIP = remoteIP.split(separator: ":").first.map(String.init) ?? remoteIP
        let cleanLocalIP = localIP.split(separator: ":").first.map(String.init) ?? localIP
        queue.async { [weak self] in
            guard let self else { return }
            if let instance = self.fileTransferInstance {
                self.receiveDirectory.path.withCString { cstr in
                    let mutable = UnsafeMutablePointer(mutating: cstr)
                    _ = self.fnSetReceivePath?(instance, mutable)
                }
                _ = self.fnRegisterReceive?(instance)
            }
            let currentState = self.fnGetClientState?() ?? 0
            if currentState != 0 && previousPort != remotePort {
                _ = self.fnStopClient?()
            }
            cleanRemoteIP.withCString { remoteCStr in
                cleanLocalIP.withCString { localCStr in
                    let mutRemote = UnsafeMutablePointer(mutating: remoteCStr)
                    let mutLocal = UnsafeMutablePointer(mutating: localCStr)
                    _ = fnClient(mutRemote, remotePort, mutLocal)
                }
            }
            if let instance = self.fileTransferInstance {
                self.receiveDirectory.path.withCString { cstr in
                    let mutable = UnsafeMutablePointer(mutating: cstr)
                    _ = self.fnSetReceivePath?(instance, mutable)
                }
                _ = self.fnRegisterReceive?(instance)
            }
        }
    }

    // MARK: - FFI Callbacks Handling

    fileprivate func handleFFIProgress(taskId: String, fileId: String, progress: Double) {
        let normalized = progress > 1.0 ? min(progress / 100.0, 1.0) : max(0.0, min(progress, 1.0))
        onTransferProgress?(taskId, fileId, normalized)
    }

    fileprivate func handleFFIState(taskId: String, fileId: String, rawState: String, message: String) {
        let upper = rawState.uppercased()

        if upper == "TASK_START", !message.isEmpty,
           let msgData = message.data(using: .utf8),
           let rawItems = try? JSONSerialization.jsonObject(with: msgData) as? [[String: Any]] {
            var incomingTasks: [TransferTaskItem] = []
            for item in rawItems {
                let fid = (item["fileId"] as? String) ?? (fileId.isEmpty ? UUID().uuidString : fileId)
                let fname = (item["fileName"] as? String)
                    ?? (item["name"] as? String)
                    ?? ((item["url"] as? String) as NSString?)?.lastPathComponent
                    ?? "手机分享文件"
                let fsize: Int64
                if let s64 = item["fileSize"] as? Int64 {
                    fsize = s64
                } else if let sInt = item["fileSize"] as? Int {
                    fsize = Int64(sInt)
                } else if let s64 = item["size"] as? Int64 {
                    fsize = s64
                } else if let sInt = item["size"] as? Int {
                    fsize = Int64(sInt)
                } else {
                    fsize = 0
                }
                let destURL = receiveDirectory.appendingPathComponent(fname)
                let task = TransferTaskItem(
                    taskId: taskId.isEmpty ? UUID().uuidString : taskId,
                    fileId: fid,
                    fileName: fname,
                    localPath: destURL.path,
                    remotePath: "手机互传分享",
                    fileSize: fsize,
                    progress: 0.05,
                    state: .transferring,
                    direction: .phoneToMac,
                    message: "正在接收手机分享文件 \(fname)..."
                )
                incomingTasks.append(task)
            }
            if !incomingTasks.isEmpty {
                onIncomingTransferStarted?(incomingTasks)
                return
            }
        }

        let mappedState: TransferTaskState
        let displayMessage: String

        if upper.contains("SUCCESS") || upper.contains("FINISH") || upper.contains("COMPLETE") {
            mappedState = .success
            displayMessage = "传输完成"
            checkNewFilesInReceiveDirectory()
        } else if upper.contains("FAIL") || upper.contains("ERROR") || upper.contains("CANCEL") {
            mappedState = .failed
            displayMessage = message.isEmpty ? "传输未完成 (\(rawState))" : message
        } else {
            mappedState = .transferring
            displayMessage = "正在高速传输..."
        }

        onTransferStateChanged?(taskId, fileId, mappedState, displayMessage)
    }

    // MARK: - Send Files from Mac to Phone (`queueSend` with `targetPath` Support)

    /// Sends Mac files or folders directly to the currently opened directory on the phone (`targetRemoteDirectory`).
    /// Follows `task2BuddleTransfer` / `pasteFiles` schema from `O+Connect`:
    /// `{"fileId", "url", "size", "isfolder", "name", "targetPath"}`.
    public func sendFilesToPhone(
        urls: [URL],
        targetDevice: OppoDevice,
        localIP: String,
        targetRemoteDirectory: String = "/storage/emulated/0"
    ) -> [TransferTaskItem] {
        var createdTasks: [TransferTaskItem] = []
        let taskId = UUID().uuidString

        let cleanTargetDir: String = {
            let trimmed = targetRemoteDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "/storage/emulated/0" }
            return trimmed.hasSuffix("/") && trimmed.count > 1 ? String(trimmed.dropLast()) : trimmed
        }()

        var oshareItems: [[String: Any]] = []
        for url in urls {
            let fileId = UUID().uuidString
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int64) ?? 0
            var isDirObj: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirObj)
            let isFolder = isDirObj.boolValue
            let fileName = url.lastPathComponent
            let fullTargetPath = "\(cleanTargetDir)/\(fileName)"

            let task = TransferTaskItem(
                taskId: taskId,
                fileId: fileId,
                fileName: fileName,
                localPath: url.path,
                remotePath: fullTargetPath,
                fileSize: size,
                progress: 0.02,
                state: .transferring,
                direction: .macToPhone,
                message: "正在上传至 \(cleanTargetDir)..."
            )
            createdTasks.append(task)
            oshareItems.append([
                "fileId": fileId,
                "path": url.path,
                "url": url.path,
                "size": size,
                "fileSize": size,
                "isfolder": isFolder,
                "isFolder": isFolder,
                "name": fileName,
                "fileName": fileName,
                "targetPath": fullTargetPath,
                "opFilePath": fullTargetPath,
                "opFilepath": fullTargetPath,
                "fileMgrVersion": 2000
            ])
        }

        startOShareServer()

        if isFFILoaded,
           let instance = fileTransferInstance,
           let fnSend = fnQueueSend,
           let jsonData = try? JSONSerialization.data(withJSONObject: oshareItems),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            let serverPort = Int(localServerPort)
            queue.async {
                taskId.withCString { taskCStr in
                    jsonStr.withCString { jsonCStr in
                        "0.0.0.0".withCString { hostCStr in
                            let mutTask = UnsafeMutablePointer(mutating: taskCStr)
                            let mutJson = UnsafeMutablePointer(mutating: jsonCStr)
                            let mutHost = UnsafeMutablePointer(mutating: hostCStr)
                            _ = fnSend(instance, mutTask, mutJson, mutHost, serverPort)
                        }
                    }
                }
            }
        }

        return createdTasks
    }

    // MARK: - Download File from Phone to Mac (`queueDownload`)

    public func downloadRemoteItemToMac(
        item: RemoteFileItem,
        targetDevice: OppoDevice,
        localIP: String
    ) -> TransferTaskItem {
        let taskId = UUID().uuidString
        let fileId = item.fileId.isEmpty ? UUID().uuidString : item.fileId
        let destinationURL = receiveDirectory.appendingPathComponent(item.fileName)

        let task = TransferTaskItem(
            taskId: taskId,
            fileId: fileId,
            fileName: item.fileName,
            localPath: destinationURL.path,
            remotePath: item.filePath,
            fileSize: item.fileSize,
            progress: 0.05,
            state: .transferring,
            direction: .phoneToMac,
            message: "正在从 \(targetDevice.deviceName) 下载 \(item.fileName)..."
        )

        let transferParams: [[String: Any]] = [
            [
                "fileId": fileId,
                "url": item.filePath,
                "fileUri": item.fileUri
            ]
        ]

        if isFFILoaded,
           let instance = fileTransferInstance,
           let fnDownload = fnQueueDownload,
           let jsonData = try? JSONSerialization.data(withJSONObject: transferParams),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            let cleanHost = targetDevice.lanIP.split(separator: ":").first.map(String.init) ?? targetDevice.lanIP
            let peerPort = remoteOSharePort > 0 ? remoteOSharePort : targetDevice.port
            queue.async { [weak self] in
                guard let self else { return }
                self.receiveDirectory.path.withCString { recvCStr in
                    let mutRecv = UnsafeMutablePointer(mutating: recvCStr)
                    _ = self.fnSetReceivePath?(instance, mutRecv)
                }
                taskId.withCString { taskCStr in
                    jsonStr.withCString { jsonCStr in
                        cleanHost.withCString { hostCStr in
                            let mutTask = UnsafeMutablePointer(mutating: taskCStr)
                            let mutJson = UnsafeMutablePointer(mutating: jsonCStr)
                            let mutHost = UnsafeMutablePointer(mutating: hostCStr)
                            _ = fnDownload(instance, mutTask, mutJson, mutHost, peerPort)
                        }
                    }
                }
            }
        }

        return task
    }

    // MARK: - Monitor Receive Directory for Incoming & Deleted Local Files

    private func snapshotReceiveDirectory() {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: receiveDirectory.path)) ?? []
        knownReceivedFileNames = Set(items)
    }

    private func startReceiveFolderMonitor() {
        folderMonitorFD = open(receiveDirectory.path, O_EVTONLY)
        guard folderMonitorFD >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: folderMonitorFD,
            eventMask: [.write, .extend, .rename, .delete, .attrib],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.checkNewFilesInReceiveDirectory()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.folderMonitorFD, fd >= 0 {
                close(fd)
            }
        }
        source.resume()
        folderMonitorSource = source
    }

    private func checkNewFilesInReceiveDirectory() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: receiveDirectory.path) else {
            return
        }
        let currentSet = Set(names)
        for name in names where !name.hasPrefix(".") && !name.hasSuffix(".tmp") && !name.hasSuffix(".part") {
            if !knownReceivedFileNames.contains(name) {
                knownReceivedFileNames.insert(name)
                let fileURL = receiveDirectory.appendingPathComponent(name)
                let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
                onFileReceivedFromPhone?(fileURL, size)
            }
        }
        // Remove deleted files from `knownReceivedFileNames` and notify UI so "已下载" badges refresh immediately
        knownReceivedFileNames = knownReceivedFileNames.intersection(currentSet)
        onReceiveDirectoryContentsChanged?()
    }
}
