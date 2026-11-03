import Foundation
import SwiftUI
import AppKit

public enum NavigationTab: String, CaseIterable, Identifiable {
    case connect = "设备"
    case transfer = "传输"
    case sms = "消息"
    case settings = "设置"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .connect: return "iphone"
        case .transfer: return "arrow.left.arrow.right"
        case .sms: return "bubble.left"
        case .settings: return "gearshape"
        }
    }
}

@MainActor
public final class ConnectCoordinator: ObservableObject {
    public static let shared = ConnectCoordinator()
    public nonisolated static let menuBarDefaultRemoteDirectory = "/storage/emulated/0/Download/ColorDrop"

    // MARK: - Published UI State

    @Published public var connectionState: ConnectionState = .scanning
    @Published public var currentSSID: String = "当前 Wi-Fi"
    @Published public var localIP: String = "127.0.0.1"
    @Published public var autoConnectOnSameWiFi: Bool = true
    @Published public var discoveredDevices: [OppoDevice] = []
    @Published public var connectedDevice: OppoDevice?
    @Published public var qrCodePayload: String = ""

    // Remote File Manager (Loaded strictly on-demand)
    @Published public var currentRemotePath: String = "/storage/emulated/0"
    @Published public var remoteFiles: [RemoteFileItem] = []
    @Published public var isLoadingFiles: Bool = false
    @Published public var showHiddenFiles: Bool = false {
        didSet {
            UserDefaults.standard.set(showHiddenFiles, forKey: "ColorDrop.ShowHiddenFiles")
        }
    }
    @Published public var selectedFileIds: Set<String> = []
    @Published public var directoryItemCounts: [String: Int] = [:]

    // Transfers & Per-File Download Feedback
    @Published public var transferTasks: [TransferTaskItem] = []
    @Published public var fileDownloadStates: [String: TransferTaskState] = [:]
    @Published public var fileDownloadProgress: [String: Double] = [:]
    @Published public var receiveDirectoryPath: String = ""
    @Published public var localFilesRevision: Int = 0

    // Messages & Incoming Phone Call Notifications ("消息")
    @Published public var smsMessages: [SMSNotificationItem] = [] {
        didSet {
            saveMessageHistory()
        }
    }
    @Published public var activeIncomingCall: IncomingCallItem?
    @Published public var autoCopyVerificationCode: Bool = true {
        didSet {
            SMSNotificationService.shared.autoCopyVerificationCode = autoCopyVerificationCode
        }
    }
    @Published public var fadeExpiredCodes: Bool = true {
        didSet {
            UserDefaults.standard.set(fadeExpiredCodes, forKey: "ColorDrop.FadeExpiredCodes")
        }
    }
    @Published public var copiedMessageId: String?
    @Published public var expandedMessageIds: Set<String> = []
    @Published public var blockedNonSMSCount: Int = 0
    @Published public var lastCopiedCode: String?

    // Telemetry & Performance Metrics
    @Published public var memoryFootprintMB: Double = 18.0
    @Published public var statusBanner: String = "正在同一 Wi-Fi 下自动搜索手机..."
    @Published public var isFFILoaded: Bool = false
    @Published public var isDaemonConnected: Bool = false
    @Published public var lastDirectoryLoadMs: Int?

    // UI Navigation & Interaction State
    @Published public var selectedTab: NavigationTab = .connect {
        didSet {
            if selectedTab == .sms {
                markAllMessagesRead()
            }
            if selectedTab == .transfer {
                syncLocalDownloadedFileStates()
                if connectedDevice != nil, remoteFiles.isEmpty, !isLoadingFiles {
                    refreshRemoteDirectory(currentRemotePath)
                }
            }
        }
    }
    @Published public var manualIPInput: String = ""
    @Published public var isDropTargeted: Bool = false
    @Published public var isMenuBarDropTargeted: Bool = false
    @Published public var hoveredFileId: String?
    @Published public var showTransferPopover: Bool = false

    // Delete Confirmation Dialog State
    @Published public var pendingDeleteItems: [RemoteFileItem] = []
    @Published public var showDeleteConfirmation: Bool = false

    public var deleteConfirmationTitle: String {
        if pendingDeleteItems.count == 1, let first = pendingDeleteItems.first {
            return first.isDirectory ? "确认删除手机文件夹？" : "确认删除手机文件？"
        }
        return "确认批量删除手机文件？"
    }

    public var deleteConfirmationMessage: String {
        if pendingDeleteItems.count == 1, let first = pendingDeleteItems.first {
            let typeLabel = first.isDirectory ? "文件夹" : "文件"
            return "确定要从手机中永久删除\(typeLabel)「\(first.fileName)」吗？此操作不可撤销。"
        }
        return "确定要从手机中永久删除选中的 \(pendingDeleteItems.count) 个项目吗？此操作不可撤销。"
    }

    public var unreadMessageCount: Int {
        smsMessages.filter { !$0.isRead }.count
    }

    public var groupedSMSMessages: [(title: String, items: [SMSNotificationItem])] {
        var groups: [(title: String, items: [SMSNotificationItem])] = []
        let sorted = smsMessages.sorted { $0.receivedAt > $1.receivedAt }
        for item in sorted {
            let groupTitle = item.groupDateTitle
            if let lastIdx = groups.indices.last, groups[lastIdx].title == groupTitle {
                groups[lastIdx].items.append(item)
            } else {
                groups.append((title: groupTitle, items: [item]))
            }
        }
        return groups
    }

    public var displayedRemoteFiles: [RemoteFileItem] {
        let filtered = showHiddenFiles ? remoteFiles : remoteFiles.filter { !$0.isHiddenItem }
        return filtered.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.fileName.localizedStandardCompare(rhs.fileName) == .orderedAscending
        }
    }

    public var nearbyUnconnectedDevices: [OppoDevice] {
        guard let connected = connectedDevice else { return discoveredDevices }
        return discoveredDevices.filter {
            $0.deviceId != connected.deviceId && $0.lanIP != connected.lanIP
        }
    }

    public var latestVerificationSMS: SMSNotificationItem? {
        smsMessages.first(where: { ($0.verificationCode?.isEmpty == false) })
    }

    public var activeTransferCount: Int {
        transferTasks.filter { $0.state == .transferring || $0.state == .pending }.count
    }

    private let discovery = LanSdpDiscovery()
    private let dspClient = DspIPCClient.shared
    private let oshare = OShareEngine.shared
    private let smsService = SMSNotificationService.shared
    private var memoryTimer: Timer?
    private var isDaemonInitialized = false
    private var lastAutoConnectAttemptByDevice: [String: Date] = [:]
    private var lastHandshakeTime: Date = .distantPast
    private var directoryRequestStartTime: Date?
    private var uploadTargetDirByTaskId: [String: String] = [:]
    private var recentlyReceivedPhonePathByName: [String: String] = [:]
    private var phoneDefaultReceivePath: String = "/storage/emulated/0/Download/OPPO 互联"
    private var categorySizesById: [Int: (bytes: Int64, count: Int)] = [:]
    private var categorySessionMap: [String: Int] = [:]
    private var indexedFilesByPath: [String: (size: Int64, category: Int)] = [:]

    // Handshake Lock & Non-Intrusive Wi-Fi Disconnect Tracking
    private var connectingLockUntil: Date = .distantPast
    private var lastReceivedPhonePacketAt: Date = Date()
    private var consecutiveICMPFailures: Int = 0
    private var consecutiveDaemonDisconnectChecks: Int = 0
    private var periodicTimerTickCount: Int = 0

    // Persistent Pairing & Auto-Reconnect State
    private let pairedIdsDefaultsKey = "OppoLite.PairedDeviceIds"
    private let pairedNamesDefaultsKey = "OppoLite.PairedDeviceNamesByIP"
    private let pairedNamesByIdDefaultsKey = "OppoLite.PairedDeviceNamesById"
    private let pairedIdsByIPDefaultsKey = "OppoLite.PairedDeviceIdsByIP"
    private let lastConnectedIdDefaultsKey = "ColorDrop.LastConnectedDeviceId"
    private let manualDisconnectDefaultsKey = "ColorDrop.UserManuallyDisconnected"
    private let messageHistoryFilePath = "/Users/micage/Documents/Gemini/oppodat/message_history.json"

    private var pairedDeviceIds: Set<String> = []
    private var knownDeviceIdByIP: [String: String] = [:]
    private var knownDeviceNameByIP: [String: String] = [:]
    private var knownDeviceNameById: [String: String] = [:]
    private var lastConnectedDeviceId: String = ""
    private var userManuallyDisconnected: Bool = false
    private var lastKnownBatteryByDeviceId: [String: (level: Int, charging: Bool)] = [:]
    private var lastKnownStorageByDeviceId: [String: (total: Int64, free: Int64)] = [:]
    private var lastKnownSwitchStatusByDeviceId: [String: (model: String, osName: String, resolution: String)] = [:]
    private var latestSwitchStatusFallback: (model: String, osName: String, resolution: String)?

    private init() {
        self.showHiddenFiles = UserDefaults.standard.bool(forKey: "ColorDrop.ShowHiddenFiles")
        if UserDefaults.standard.object(forKey: "ColorDrop.FadeExpiredCodes") != nil {
            self.fadeExpiredCodes = UserDefaults.standard.bool(forKey: "ColorDrop.FadeExpiredCodes")
        }
        self.receiveDirectoryPath = oshare.receiveDirectory.path
        loadPairedDeviceHistory()
        loadMessageHistory()
        seedRecentDeviceAndBatteryStateFromDaemonLog()

        self.currentSSID = discovery.currentSSID
        self.localIP = discovery.localIPv4
        self.isFFILoaded = oshare.isFFILoaded
        self.isDaemonConnected = dspClient.isDaemonAvailable
        self.memoryFootprintMB = MemoryTelemetry.currentFootprintMB()
        self.qrCodePayload = DspIPCClient.buildFormattedQRCodeUrl(
            fromRawDaemonJson: nil,
            localIP: discovery.localIPv4,
            ssid: discovery.currentSSID,
            deviceId: discovery.localDeviceId
        )

        setupCallbacks()
        startServices()
    }

    // MARK: - Dynamic Local File Existence Check (`✓ 已下载` Sync)

    public func effectiveDownloadState(for item: RemoteFileItem) -> TransferTaskState? {
        _ = localFilesRevision
        if item.isDirectory { return nil }
        if fileDownloadStates[item.filePath] == .transferring {
            return .transferring
        }
        if oshare.isFilePresentInReceiveDirectory(fileName: item.fileName) && fileDownloadStates[item.filePath] == .success {
            return .success
        }
        return nil
    }

    public func syncLocalDownloadedFileStates() {
        var changed = false
        for (remotePath, state) in fileDownloadStates where state == .success {
            let fileName = (remotePath as NSString).lastPathComponent
            if !oshare.isFilePresentInReceiveDirectory(fileName: fileName) {
                fileDownloadStates.removeValue(forKey: remotePath)
                fileDownloadProgress.removeValue(forKey: remotePath)
                changed = true
            }
        }
        if changed {
            localFilesRevision &+= 1
        }
    }

    // MARK: - Persistence & Daemon Log Seeding (Model Names & Battery Level)

    private func loadPairedDeviceHistory() {
        if let savedIds = UserDefaults.standard.stringArray(forKey: pairedIdsDefaultsKey) {
            pairedDeviceIds.formUnion(savedIds)
        }
        if let savedByIP = UserDefaults.standard.dictionary(forKey: pairedIdsByIPDefaultsKey) as? [String: String] {
            for (k, v) in savedByIP { knownDeviceIdByIP[k] = v }
        }
        if let savedNames = UserDefaults.standard.dictionary(forKey: pairedNamesDefaultsKey) as? [String: String] {
            for (k, v) in savedNames { knownDeviceNameByIP[k] = v }
        }
        if let savedNamesById = UserDefaults.standard.dictionary(forKey: pairedNamesByIdDefaultsKey) as? [String: String] {
            for (k, v) in savedNamesById { knownDeviceNameById[k] = v }
        }
        self.lastConnectedDeviceId = UserDefaults.standard.string(forKey: lastConnectedIdDefaultsKey) ?? ""
        self.userManuallyDisconnected = UserDefaults.standard.bool(forKey: manualDisconnectDefaultsKey)
    }

    private func rememberPairedDevice(_ device: OppoDevice) {
        let isSyntheticId = device.deviceId.hasPrefix("10C0A8") || device.deviceId.hasPrefix("oppo-")
        if !device.deviceId.isEmpty && !isSyntheticId {
            pairedDeviceIds.insert(device.deviceId)
            lastConnectedDeviceId = device.deviceId
            UserDefaults.standard.set(Array(pairedDeviceIds), forKey: pairedIdsDefaultsKey)
            UserDefaults.standard.set(lastConnectedDeviceId, forKey: lastConnectedIdDefaultsKey)
            if !device.lanIP.isEmpty {
                knownDeviceIdByIP[device.lanIP] = device.deviceId
                UserDefaults.standard.set(knownDeviceIdByIP, forKey: pairedIdsByIPDefaultsKey)
            }
            if device.hasSpecificModelName {
                knownDeviceNameById[device.deviceId] = device.deviceName
                UserDefaults.standard.set(knownDeviceNameById, forKey: pairedNamesByIdDefaultsKey)
            }
        }
        if !device.lanIP.isEmpty && device.hasSpecificModelName {
            knownDeviceNameByIP[device.lanIP] = device.deviceName
            UserDefaults.standard.set(knownDeviceNameByIP, forKey: pairedNamesDefaultsKey)
        }
    }

    private func seedRecentDeviceAndBatteryStateFromDaemonLog() {
        let logDir = "/Users/micage/Documents/Gemini/dsplogs-daemon"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: logDir) else { return }
        let logFiles = files.filter { $0.hasSuffix(".log") && !$0.contains("crash") }.sorted()
        guard let latestLog = logFiles.last else { return }
        let fullPath = "\(logDir)/\(latestLog)"
        guard let handle = FileHandle(forReadingAtPath: fullPath) else { return }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        let readBytes: UInt64 = min(fileSize, 512_000)
        try? handle.seek(toOffset: fileSize - readBytes)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return }

        let currentLocalIP = discovery.localIPv4
        for line in text.split(separator: "\n") {
            if line.contains("publish eventId: onAgentFound msg: "),
               let range = line.range(of: "msg: ") {
                let jsonStr = String(line[range.upperBound...])
                if let jData = jsonStr.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: jData) as? [String: Any] {
                    let devId = (dict["protcol_device_id"] as? String) ?? (dict["device_id"] as? String) ?? ""
                    let devName = (dict["device_name"] as? String) ?? ""
                    let rawAddr = (dict["connect_address"] as? String) ?? ""
                    let unmasked = DspIPCClient.unmaskDaemonIP(rawAddr, localIP: currentLocalIP)
                    let ip = unmasked.split(separator: ":").first.map(String.init) ?? ""
                    if !devId.isEmpty && !devName.isEmpty {
                        knownDeviceNameById[devId] = devName
                    }
                    if !ip.isEmpty && !devName.isEmpty {
                        knownDeviceNameByIP[ip] = devName
                    }
                    if !ip.isEmpty && !devId.isEmpty {
                        knownDeviceIdByIP[ip] = devId
                    }
                }
            } else if line.contains("publish eventId: onPeerDeviceInfoChanged msg: "),
                      let range = line.range(of: "msg: ") {
                let jsonStr = String(line[range.upperBound...])
                if let jData = jsonStr.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: jData) as? [String: Any],
                   let devId = dict["device_id"] as? String,
                   let batStr = dict["batteryInfo"] as? String,
                   let batData = batStr.data(using: .utf8),
                   let batJson = try? JSONSerialization.jsonObject(with: batData) as? [String: Any],
                   let level = batJson["batteryLevel"] as? Int {
                    let charging = ((batJson["batteryCharging"] as? Int) ?? 0) != 0
                    lastKnownBatteryByDeviceId[devId] = (level: level, charging: charging)
                }
            } else if line.contains("switchStatus") && line.contains("OPverionCode") {
                if let range = line.range(of: "res_json "),
                   let jData = String(line[range.upperBound...]).data(using: .utf8),
                   let outer = try? JSONSerialization.jsonObject(with: jData) as? [String: Any],
                   let topicStr = outer["topic_message"] as? String,
                   let tData = topicStr.data(using: .utf8),
                   let tJson = try? JSONSerialization.jsonObject(with: tData) as? [String: Any],
                   let valStr = tJson["value"] as? String,
                   let vData = valStr.data(using: .utf8),
                   let vJson = try? JSONSerialization.jsonObject(with: vData) as? [String: Any] {
                    applySwitchStatusPayload(vJson, deviceId: lastConnectedDeviceId)
                }
            }
        }
    }

    private func applySwitchStatusPayload(_ payload: [String: Any], deviceId: String = "") {
        let model = ((payload["PhoneModel"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let resolution = ((payload["Resolution"] as? String) ?? (payload["BigResolution"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let opVerInt: Int = {
            if let v = payload["OPverionCode"] as? Int { return v }
            if let v = payload["OPversionCode"] as? Int { return v }
            if let s = payload["OPverionCode"] as? String, let p = Int(s) { return p }
            if let s = payload["OPversionCode"] as? String, let p = Int(s) { return p }
            return 0
        }()
        let osName: String = {
            if opVerInt >= 100_000_000 {
                let major = opVerInt / 10_000_000
                return "ColorOS \(major)"
            }
            return "ColorOS 17"
        }()
        let info = (model: model, osName: osName, resolution: resolution)
        latestSwitchStatusFallback = info
        let targetId = deviceId.isEmpty ? (connectedDevice?.deviceId ?? lastConnectedDeviceId) : deviceId
        if !targetId.isEmpty {
            lastKnownSwitchStatusByDeviceId[targetId] = info
        }
        if connectedDevice != nil {
            if !model.isEmpty { connectedDevice?.phoneModel = model }
            connectedDevice?.osVersionName = osName
            if !resolution.isEmpty { connectedDevice?.screenResolution = resolution }
            let modelSuffix = model.isEmpty ? "" : " · \(model)"
            connectedDevice?.systemVersion = "\(osName)\(modelSuffix) · ColorDrop v1.0.1"
        }
    }

    private func loadMessageHistory() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: messageHistoryFilePath)),
              let decoded = try? JSONDecoder().decode([SMSNotificationItem].self, from: data) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-86_400)
        self.smsMessages = decoded.filter { $0.receivedAt >= cutoff }.sorted { $0.receivedAt > $1.receivedAt }
    }

    private func saveMessageHistory() {
        let snapshot = Array(smsMessages.prefix(50))
        if let encoded = try? JSONEncoder().encode(snapshot) {
            try? encoded.write(to: URL(fileURLWithPath: messageHistoryFilePath), options: .atomic)
        }
    }

    private func shouldAutoConnect(to device: OppoDevice) -> Bool {
        guard autoConnectOnSameWiFi && !userManuallyDisconnected else { return false }
        if !lastConnectedDeviceId.isEmpty && device.deviceId == lastConnectedDeviceId {
            return true
        }
        if pairedDeviceIds.contains(device.deviceId) {
            return true
        }
        let isSyntheticId = device.deviceId == LanSdpDiscovery.deterministicDeviceId(forIP: device.lanIP)
            || device.deviceId.hasPrefix("oppo-")
        if isSyntheticId, let knownId = knownDeviceIdByIP[device.lanIP], pairedDeviceIds.contains(knownId) {
            return true
        }
        return false
    }

    // MARK: - Setup Callbacks

    private func setupCallbacks() {
        discovery.onWiFiChanged = { [weak self] ssid, ip in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentSSID = ssid
                self.localIP = ip
                self.qrCodePayload = await self.dspClient.fetchQrCodeInfo(
                    localIP: ip,
                    ssid: ssid,
                    fallbackDeviceId: self.discovery.localDeviceId
                )
                if !self.discovery.hasValidLANIP, self.connectedDevice != nil {
                    self.handlePeerDisconnected(byUser: false)
                    return
                }
                if self.connectedDevice == nil {
                    self.statusBanner = "已在同一 Wi-Fi 就绪"
                }
                if self.autoConnectOnSameWiFi && Date() >= self.connectingLockUntil {
                    await self.dspClient.probeDevices()
                    await self.pollDspDaemonDevice()
                }
            }
        }

        discovery.onDeviceDiscovered = { [weak self] device in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.discovery.isSelfAddress(device.lanIP, serviceName: device.deviceName, deviceId: device.deviceId) else {
                    return
                }
                let enriched = self.enrichDeviceWithKnownMetadata(device)
                self.upsertDiscoveredDevice(enriched)
                await self.attemptAutoReconnectIfEligible(enriched)
            }
        }

        dspClient.onDiscoveryEvent = { [weak self] eventDict in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleDspDiscoveryEvent(eventDict)
            }
        }

        dspClient.onDeviceLostEvent = { [weak self] eventDict in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let lostId = (eventDict["protcol_device_id"] as? String)
                    ?? (eventDict["device_id"] as? String)
                    ?? ""
                if !lostId.isEmpty && self.connectedDevice?.deviceId != lostId {
                    self.discoveredDevices.removeAll { $0.deviceId == lostId }
                }
            }
        }

        dspClient.onPeerDeviceInfoChanged = { [weak self] eventDict in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastReceivedPhonePacketAt = Date()
                self.consecutiveICMPFailures = 0
                self.handlePeerDeviceInfoChanged(eventDict)
            }
        }

        dspClient.onConnectEvent = { [weak self] eventDict in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.handleDspConnectEvent(eventDict)
            }
        }

        dspClient.onAgentConnected = { [weak self] deviceId in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastReceivedPhonePacketAt = Date()
                self.consecutiveICMPFailures = 0
                await self.handleAgentConnected(deviceId: deviceId)
            }
        }

        dspClient.onAgentDisconnected = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isLoadingFiles = false
            }
        }

        dspClient.onAgentMessage = { [weak self] deviceId, msgObj in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastReceivedPhonePacketAt = Date()
                self.consecutiveICMPFailures = 0
                await self.handleIncomingAgentMessage(deviceId: deviceId, msg: msgObj)
            }
        }

        dspClient.onDataBusEvent = { [weak self] eventDict in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastReceivedPhonePacketAt = Date()
                self.consecutiveICMPFailures = 0
                self.handleIncomingDataBusEvent(eventDict)
            }
        }

        oshare.onReceiveDirectoryContentsChanged = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncLocalDownloadedFileStates()
                self.localFilesRevision &+= 1
            }
        }

        oshare.onIncomingTransferStarted = { [weak self] incomingTasks in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastReceivedPhonePacketAt = Date()
                for task in incomingTasks {
                    if !self.transferTasks.contains(where: { $0.taskId == task.taskId && $0.fileId == task.fileId }) {
                        self.transferTasks.insert(task, at: 0)
                    }
                }
                if let first = incomingTasks.first {
                    self.statusBanner = "正在接收手机文件：\(first.fileName)..."
                }
            }
        }

        oshare.onTransferProgress = { [weak self] taskId, fileId, progress in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastReceivedPhonePacketAt = Date()
                if let idx = self.transferTasks.firstIndex(where: {
                    $0.taskId == taskId && (fileId.isEmpty || $0.fileId == fileId)
                }) {
                    self.transferTasks[idx].progress = progress
                    self.transferTasks[idx].state = progress >= 1.0 ? .success : .transferring
                    let remotePath = self.transferTasks[idx].remotePath
                    if !remotePath.isEmpty && self.transferTasks[idx].direction == .phoneToMac {
                        self.fileDownloadProgress[remotePath] = progress
                        self.fileDownloadStates[remotePath] = progress >= 1.0 ? .success : .transferring
                    }
                }
            }
        }

        oshare.onTransferStateChanged = { [weak self] taskId, fileId, state, message in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastReceivedPhonePacketAt = Date()
                if let idx = self.transferTasks.firstIndex(where: {
                    $0.taskId == taskId && (fileId.isEmpty || $0.fileId == fileId)
                }) {
                    self.transferTasks[idx].state = state
                    if state == .success {
                        self.transferTasks[idx].progress = 1.0
                    }
                    if !message.isEmpty {
                        self.transferTasks[idx].message = message
                    }
                    let task = self.transferTasks[idx]
                    if task.direction == .phoneToMac && !task.remotePath.isEmpty {
                        self.fileDownloadStates[task.remotePath] = state
                        if state == .success {
                            self.fileDownloadProgress[task.remotePath] = 1.0
                            self.localFilesRevision &+= 1
                        }
                    } else if task.direction == .macToPhone && state == .success {
                        await self.ensureUploadedFileInTargetFolder(task: task)
                    }
                }
                if !message.isEmpty {
                    self.statusBanner = message
                }
            }
        }

        oshare.onFileReceivedFromPhone = { [weak self] fileURL, fileSize in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastReceivedPhonePacketAt = Date()
                let fname = fileURL.lastPathComponent
                for (remotePath, dState) in self.fileDownloadStates where dState == .transferring {
                    if (remotePath as NSString).lastPathComponent == fname {
                        self.fileDownloadStates[remotePath] = .success
                        self.fileDownloadProgress[remotePath] = 1.0
                    }
                }
                self.localFilesRevision &+= 1
                if let idx = self.transferTasks.firstIndex(where: {
                    $0.direction == .phoneToMac && $0.fileName == fname && $0.state != .success
                }) {
                    self.transferTasks[idx].state = .success
                    self.transferTasks[idx].progress = 1.0
                    self.transferTasks[idx].localPath = fileURL.path
                    if fileSize > 0 {
                        self.transferTasks[idx].fileSize = fileSize
                    }
                    self.transferTasks[idx].message = "已接收并保存至「\(self.oshare.receiveDirectory.lastPathComponent)」"
                } else if !self.transferTasks.contains(where: { $0.localPath == fileURL.path }) {
                    let item = TransferTaskItem(
                        fileName: fname,
                        localPath: fileURL.path,
                        remotePath: "手机端发送",
                        fileSize: fileSize,
                        progress: 1.0,
                        state: .success,
                        direction: .phoneToMac,
                        message: "已接收手机文件，保存在「\(self.oshare.receiveDirectory.lastPathComponent)」"
                    )
                    self.transferTasks.insert(item, at: 0)
                }
                self.statusBanner = "已保存手机文件：\(fname)"
            }
        }

        smsService.onSMSReceived = { [weak self] item in
            Task { @MainActor [weak self] in
                guard let self else { return }
                var incoming = item
                if self.selectedTab == .sms {
                    incoming.isRead = true
                }
                if let idx = self.smsMessages.firstIndex(where: { $0.id == incoming.id }) {
                    incoming.isRead = self.smsMessages[idx].isRead || (self.selectedTab == .sms)
                    self.smsMessages[idx] = incoming
                } else {
                    self.smsMessages.insert(incoming, at: 0)
                }
                if let code = incoming.verificationCode, !code.isEmpty {
                    self.lastCopiedCode = code
                    self.statusBanner = "收到验证码 \(code)"
                } else {
                    self.statusBanner = "收到来自 \(incoming.senderTitle) 的通知"
                }
            }
        }

        smsService.onActiveCallChanged = { [weak self] callItem in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.activeIncomingCall = callItem
            }
        }

        smsService.onBlockedCountChanged = { [weak self] count in
            Task { @MainActor [weak self] in
                self?.blockedNonSMSCount = count
            }
        }
    }

    private func ensureUploadedFileInTargetFolder(task: TransferTaskItem) async {
        guard let dev = connectedDevice else { return }
        let targetDir = uploadTargetDirByTaskId[task.taskId] ?? currentRemotePath
        let cleanDir = targetDir.hasSuffix("/") && targetDir.count > 1 ? String(targetDir.dropLast()) : targetDir
        let fileName = task.fileName

        // If target is `/storage/emulated/0/Download/ColorDrop` (or another custom subfolder), ensure the folder exists first
        if cleanDir == Self.menuBarDefaultRemoteDirectory {
            let mkdirPayload = dspClient.buildCreateFolderPayload(
                parentPath: "/storage/emulated/0/Download",
                folderName: "ColorDrop"
            )
            await dspClient.sendAgentMessage(deviceId: dev.deviceId, jsonObject: mkdirPayload)
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        if !cleanDir.hasSuffix("/OPPO Share")
            && !cleanDir.hasSuffix("/OPPO 互联")
            && !cleanDir.hasSuffix("/OShare") {
            var candidateSources: [String] = []
            if let exactRecent = recentlyReceivedPhonePathByName[fileName],
               !exactRecent.isEmpty,
               (exactRecent as NSString).deletingLastPathComponent != cleanDir {
                candidateSources.append(exactRecent)
            }
            let candidateDefaultDirs = [
                phoneDefaultReceivePath,
                "/storage/emulated/0/Download/OPPO 互联",
                "/storage/emulated/0/OPPO 互联",
                "/storage/emulated/0/Download/OPPO Share",
                "/storage/emulated/0/Download/OShare",
                "/storage/emulated/0/Download"
            ]
            for defaultDir in candidateDefaultDirs where defaultDir != cleanDir {
                let candidateSource = "\(defaultDir)/\(fileName)"
                if !candidateSources.contains(candidateSource) {
                    candidateSources.append(candidateSource)
                }
            }
            for candidateSource in candidateSources {
                let movePayload = dspClient.buildMoveFilesPayload(
                    sourceItems: [(path: candidateSource, name: fileName)],
                    targetFolderPath: cleanDir
                )
                await dspClient.sendAgentMessage(deviceId: dev.deviceId, jsonObject: movePayload)
            }
        }

        try? await Task.sleep(nanoseconds: 550_000_000)
        if selectedTab == .transfer {
            refreshRemoteDirectory(currentRemotePath)
        }
    }

    // MARK: - Device Metadata Enrichment & Safe Auto-Reconnect

    private func enrichDeviceWithKnownMetadata(_ device: OppoDevice) -> OppoDevice {
        var updated = device
        let isSyntheticId = updated.deviceId == LanSdpDiscovery.deterministicDeviceId(forIP: updated.lanIP)
            || updated.deviceId.hasPrefix("oppo-")
        let resolvedId: String
        if isSyntheticId, let knownId = knownDeviceIdByIP[updated.lanIP], !knownId.isEmpty {
            resolvedId = knownId
        } else {
            resolvedId = updated.deviceId
        }
        if !updated.hasSpecificModelName {
            if let nameById = knownDeviceNameById[resolvedId], !nameById.isEmpty {
                updated.deviceName = nameById
            } else if let nameByIP = knownDeviceNameByIP[updated.lanIP], !nameByIP.isEmpty {
                updated.deviceName = nameByIP
            }
        }
        let batInfo = lastKnownBatteryByDeviceId[resolvedId]
        let storageInfo = lastKnownStorageByDeviceId[resolvedId]
        let switchInfo = lastKnownSwitchStatusByDeviceId[resolvedId] ?? latestSwitchStatusFallback
        let isPaired = pairedDeviceIds.contains(resolvedId)
        return OppoDevice(
            deviceId: resolvedId,
            deviceName: updated.deviceName,
            lanIP: updated.lanIP,
            port: updated.port,
            connectType: updated.connectType,
            ssid: updated.ssid,
            batteryLevel: updated.batteryLevel ?? batInfo?.level,
            isCharging: updated.isCharging || (batInfo?.charging ?? false),
            systemVersion: updated.systemVersion,
            phoneModel: updated.phoneModel ?? switchInfo?.model,
            osVersionName: updated.osVersionName ?? switchInfo?.osName,
            screenResolution: updated.screenResolution ?? switchInfo?.resolution,
            storageSummary: updated.storageSummary,
            storageTotalBytes: updated.storageTotalBytes ?? storageInfo?.total,
            storageFreeBytes: updated.storageFreeBytes ?? storageInfo?.free,
            indexedMediaBytes: updated.indexedMediaBytes,
            indexedMediaCount: updated.indexedMediaCount,
            categoryBreakdownText: updated.categoryBreakdownText,
            rootFolderCount: updated.rootFolderCount,
            pingLatencyMs: updated.pingLatencyMs,
            isPaired: isPaired,
            isSameAccount: updated.isSameAccount,
            discoverySource: updated.discoverySource,
            lastSeen: updated.lastSeen
        )
    }

    private func attemptAutoReconnectIfEligible(_ device: OppoDevice) async {
        guard connectedDevice == nil,
              connectionState != .connecting,
              Date() >= connectingLockUntil,
              shouldAutoConnect(to: device) else {
            return
        }
        let key = device.deviceId
        let now = Date()
        if let last = lastAutoConnectAttemptByDevice[key], now.timeIntervalSince(last) < 25.0 {
            return
        }
        lastAutoConnectAttemptByDevice[key] = now
        await requestDspConnection(to: device)
    }

    // MARK: - Handle Real Discovery (`onAgentFound`), Battery (`onPeerDeviceInfoChanged`), Connect & Agent Events

    private func handlePeerDeviceInfoChanged(_ dict: [String: Any]) {
        let devId = (dict["device_id"] as? String) ?? connectedDevice?.deviceId ?? ""
        if let batStr = dict["batteryInfo"] as? String,
           let batData = batStr.data(using: .utf8),
           let batJson = try? JSONSerialization.jsonObject(with: batData) as? [String: Any],
           let level = batJson["batteryLevel"] as? Int {
            let charging = ((batJson["batteryCharging"] as? Int) ?? 0) != 0
            if !devId.isEmpty {
                lastKnownBatteryByDeviceId[devId] = (level: level, charging: charging)
            }
            if connectedDevice != nil && (devId.isEmpty || connectedDevice?.deviceId == devId) {
                connectedDevice?.batteryLevel = level
                connectedDevice?.isCharging = charging
            }
        }
        extractAndApplyStorageCapacity(from: dict, deviceId: devId)
    }

    private func extractAndApplyStorageCapacity(from dict: [String: Any], deviceId: String) {
        let totalKeys = ["totalSize", "totalSpace", "totalBytes", "storageTotal", "romTotal", "maxSize", "totalCapacity"]
        let freeKeys = ["freeSize", "freeSpace", "availSize", "availableSize", "availableBytes", "storageFree", "romFree", "freeCapacity"]
        let usedKeys = ["usedSize", "usedSpace", "usedBytes", "storageUsed"]

        func readInt64(_ obj: [String: Any], keys: [String]) -> Int64? {
            for k in keys {
                if let v = obj[k] as? Int64, v > 0 { return v }
                if let v = obj[k] as? Int, v > 0 { return Int64(v) }
                if let v = obj[k] as? Double, v > 0 { return Int64(v) }
                if let s = obj[k] as? String, let parsed = Int64(s), parsed > 0 { return parsed }
            }
            return nil
        }

        var candidateDicts: [[String: Any]] = [dict]
        if let res = dict["result"] as? [String: Any] {
            candidateDicts.append(res)
            if let dataDict = res["data"] as? [String: Any] {
                candidateDicts.append(dataDict)
            } else if let dataArr = res["data"] as? [[String: Any]] {
                candidateDicts.append(contentsOf: dataArr)
            }
        }
        if let bodyDict = dict["body"] as? [String: Any] {
            candidateDicts.append(bodyDict)
        }

        for d in candidateDicts {
            if let total = readInt64(d, keys: totalKeys), total > 100_000_000 {
                let free: Int64
                if let f = readInt64(d, keys: freeKeys) {
                    free = f
                } else if let u = readInt64(d, keys: usedKeys), total >= u {
                    free = total - u
                } else {
                    continue
                }
                let targetId = deviceId.isEmpty ? (connectedDevice?.deviceId ?? "") : deviceId
                if !targetId.isEmpty {
                    lastKnownStorageByDeviceId[targetId] = (total: total, free: free)
                }
                if connectedDevice != nil {
                    connectedDevice?.storageTotalBytes = total
                    connectedDevice?.storageFreeBytes = free
                }
                return
            }
        }
    }

    private func handleDspDiscoveryEvent(_ dict: [String: Any]) {
        let dataDict: [String: Any]
        if let inner = dict["data"] as? [String: Any] {
            dataDict = inner
        } else if let dataStr = dict["data"] as? String,
                  let d = dataStr.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            dataDict = parsed
        } else {
            dataDict = dict
        }

        let deviceId = (dataDict["protcol_device_id"] as? String)
            ?? (dataDict["protocol_device_id"] as? String)
            ?? (dataDict["device_id"] as? String)
            ?? ""
        let rawName = (dataDict["device_name"] as? String)
            ?? (dataDict["friendly_name"] as? String)
            ?? ""
        let addrRaw = (dataDict["connect_address"] as? String)
            ?? (dataDict["device_address"] as? String)
            ?? (dataDict["scp_address"] as? String)
            ?? (dataDict["lan_ip"] as? String)
            ?? ""
        let unmaskedAddr = DspIPCClient.unmaskDaemonIP(addrRaw, localIP: localIP)
        let parts = unmaskedAddr.split(separator: ":")
        let ip = parts.first.map(String.init) ?? unmaskedAddr
        let port = parts.count > 1 ? (Int(parts[1]) ?? 10152) : 10152
        guard !deviceId.isEmpty || !ip.isEmpty else { return }
        guard !discovery.isSelfAddress(ip, serviceName: rawName, deviceId: deviceId) else { return }

        if !deviceId.isEmpty && !rawName.isEmpty && !rawName.hasPrefix("OPPO / 一加手机") {
            knownDeviceNameById[deviceId] = rawName
            UserDefaults.standard.set(knownDeviceNameById, forKey: pairedNamesByIdDefaultsKey)
        }
        if !ip.isEmpty && !deviceId.isEmpty {
            knownDeviceIdByIP[ip] = deviceId
            UserDefaults.standard.set(knownDeviceIdByIP, forKey: pairedIdsByIPDefaultsKey)
        }
        if !ip.isEmpty && !rawName.isEmpty && !rawName.hasPrefix("OPPO / 一加手机") {
            knownDeviceNameByIP[ip] = rawName
            UserDefaults.standard.set(knownDeviceNameByIP, forKey: pairedNamesDefaultsKey)
        }

        let resolvedId = deviceId.isEmpty ? (knownDeviceIdByIP[ip] ?? LanSdpDiscovery.deterministicDeviceId(forIP: ip)) : deviceId
        let resolvedName = !rawName.isEmpty ? rawName : (knownDeviceNameById[resolvedId] ?? knownDeviceNameByIP[ip] ?? "手机 (\(ip))")
        let batInfo = lastKnownBatteryByDeviceId[resolvedId]

        let dev = OppoDevice(
            deviceId: resolvedId,
            deviceName: resolvedName,
            lanIP: ip.isEmpty ? "同局域网" : ip,
            port: port,
            connectType: (dataDict["connect_type"] as? Int) ?? 16,
            ssid: currentSSID,
            batteryLevel: batInfo?.level,
            isCharging: batInfo?.charging ?? false,
            isPaired: pairedDeviceIds.contains(resolvedId),
            isSameAccount: (dataDict["is_same_account"] as? Bool) ?? false,
            discoverySource: .dspDaemon
        )
        upsertDiscoveredDevice(dev)

        Task {
            await attemptAutoReconnectIfEligible(dev)
        }
    }

    private func handleDspConnectEvent(_ dict: [String: Any]) async {
        let event = (dict["event"] as? String) ?? (dict["state"] as? String) ?? ""
        let dataDict: [String: Any]
        if let inner = dict["data"] as? [String: Any] {
            dataDict = inner
        } else if let dataStr = dict["data"] as? String,
                  let d = dataStr.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            dataDict = parsed
        } else {
            dataDict = dict
        }

        if event == "onConnectRequested" {
            let deviceId = (dataDict["device_id"] as? String)
                ?? (dataDict["protcol_device_id"] as? String)
                ?? ""
            let connectType = (dataDict["connect_type"] as? Int) ?? 0
            let deviceAddress = (dataDict["device_address"] as? String)
                ?? (dataDict["connect_address"] as? String)
                ?? (dataDict["scp_address"] as? String)
                ?? ""
            let deviceName = (dataDict["device_name"] as? String) ?? "手机"
            connectingLockUntil = Date().addingTimeInterval(25.0)
            statusBanner = "收到 \(deviceName) 的连接请求，正在自动接受..."
            await dspClient.acceptConnection(deviceId: deviceId, connectType: connectType, deviceAddress: deviceAddress)
            return
        }

        if event == "onRequestConfirm" {
            let deviceName = (dataDict["device_name"] as? String) ?? "手机"
            connectingLockUntil = Date().addingTimeInterval(30.0)
            connectionState = .connecting
            statusBanner = "请在 \(deviceName) 手机弹窗中点击「连接」"
            return
        }

        if event == "onPeerAccepted" {
            connectingLockUntil = Date().addingTimeInterval(15.0)
            statusBanner = "手机已接受连接，正在建立高速通道..."
            return
        }

        if event == "onConnected" {
            connectingLockUntil = .distantPast
            lastReceivedPhonePacketAt = Date()
            consecutiveICMPFailures = 0
            consecutiveDaemonDisconnectChecks = 0

            let deviceId = (dataDict["device_id"] as? String)
                ?? (dataDict["protcol_device_id"] as? String)
                ?? ""
            let deviceName = (dataDict["device_name"] as? String) ?? knownDeviceNameById[deviceId] ?? "手机"
            let connectType = (dataDict["connect_type"] as? Int) ?? 16
            let addrRaw = (dataDict["device_address"] as? String)
                ?? (dataDict["connect_address"] as? String)
                ?? (dataDict["scp_address"] as? String)
                ?? ""
            let unmasked = DspIPCClient.unmaskDaemonIP(addrRaw, localIP: localIP)
            let ip = unmasked.split(separator: ":").first.map(String.init) ?? unmasked

            await pollDspDaemonDevice()
            if connectedDevice == nil, !deviceId.isEmpty {
                let batInfo = lastKnownBatteryByDeviceId[deviceId]
                let dev = OppoDevice(
                    deviceId: deviceId,
                    deviceName: deviceName,
                    lanIP: (ip.isEmpty || ip.hasPrefix("*")) ? (knownDeviceIdByIP.first(where: { $0.value == deviceId })?.key ?? localIP) : ip,
                    port: 10152,
                    connectType: connectType,
                    ssid: currentSSID,
                    batteryLevel: batInfo?.level,
                    isCharging: batInfo?.charging ?? false,
                    isPaired: true,
                    discoverySource: .dspDaemon
                )
                await finalizeConnectedDevice(dev)
            }
            return
        }

        if event == "onError" {
            connectingLockUntil = Date().addingTimeInterval(8.0)
            if connectedDevice == nil {
                connectionState = .disconnected
                statusBanner = "连接超时或未在手机上确认，可再次点击「连接」"
            }
            return
        }

        if event == "onDisconnected" || event.lowercased().contains("disconnect") {
            connectingLockUntil = Date().addingTimeInterval(4.0)
            handlePeerDisconnected(byUser: false)
            return
        }

        await pollDspDaemonDevice()
    }

    private func handleAgentConnected(deviceId: String) async {
        guard let dev = connectedDevice else { return }
        let targetId = deviceId.isEmpty ? dev.deviceId : deviceId
        await triggerOShareHandshakeIfNeeded(deviceId: targetId)
    }

    private func triggerOShareHandshakeIfNeeded(deviceId: String) async {
        let now = Date()
        guard now.timeIntervalSince(lastHandshakeTime) > 3.5 else { return }
        lastHandshakeTime = now
        await sendOShareHandshakeMessages(deviceId: deviceId)
        if selectedTab == .transfer && remoteFiles.isEmpty {
            refreshRemoteDirectory(currentRemotePath)
        }
    }

    private func sendOShareHandshakeMessages(deviceId: String) async {
        guard !deviceId.isEmpty else { return }
        oshare.startOShareServer()

        let capSync: [String: Any] = [
            "api": "init.capability.sync",
            "sessionId": UUID().uuidString,
            "header": ["clientVersion": "1.0.0", "apilevel": "1"],
            "body": ["fileMgrVersion": 2000]
        ]
        await dspClient.sendAgentMessage(deviceId: deviceId, jsonObject: capSync)

        let portStr = String(oshare.localServerPort)
        let clientStartMsg: [String: Any] = [
            "api": "websocket.request",
            "sessionId": UUID().uuidString,
            "header": ["clientVersion": "1.0.0", "apilevel": "1"],
            "body": [
                "method": "clientstart",
                "port": portStr
            ]
        ]
        let serverStartMsg: [String: Any] = [
            "api": "websocket.request",
            "sessionId": UUID().uuidString,
            "header": ["clientVersion": "1.0.0", "apilevel": "1"],
            "body": [
                "method": "serverstart",
                "ip": localIP,
                "port": portStr
            ]
        ]
        await dspClient.sendAgentMessage(deviceId: deviceId, jsonObject: clientStartMsg)
        await dspClient.sendAgentMessage(deviceId: deviceId, jsonObject: serverStartMsg)

        let rootPayload = dspClient.buildFileRootPayload()
        await dspClient.sendAgentMessage(deviceId: deviceId, jsonObject: rootPayload)

        let rootListPayload = dspClient.buildRemoteListPayload(remotePath: "/storage/emulated/0", pageNo: 1, pageSize: 500, includeThumbnails: false)
        await dspClient.sendAgentMessage(deviceId: deviceId, jsonObject: rootListPayload)

        Task {
            for catId in [1, 2, 3, 4, 32] {
                try? await Task.sleep(nanoseconds: 550_000_000)
                let sid = "CAT_\(catId)_\(UUID().uuidString)"
                self.categorySessionMap[sid] = catId
                let catPayload = dspClient.buildCategoryQueryPayload(categoryId: catId, sessionId: sid)
                await dspClient.sendAgentMessage(deviceId: deviceId, jsonObject: catPayload)
            }
        }
    }

    private func recordIndexedFiles(_ items: [RemoteFileItem], defaultCategory: Int = 0) {
        for item in items where !item.isDirectory && item.fileSize > 0 {
            let cat: Int = {
                if item.isImage { return 1 }
                if item.isVideo { return 2 }
                let ext = item.fileExtensionLabel.lowercased()
                if ["mp3", "aac", "wav", "flac", "ogg", "m4a"].contains(ext) { return 3 }
                if ["zip", "rar", "7z", "tar", "gz", "apk"].contains(ext) { return 32 }
                if defaultCategory != 0 { return defaultCategory }
                return 4
            }()
            indexedFilesByPath[item.filePath] = (size: item.fileSize, category: cat)
        }
        recomputeSharedFileMetrics()
    }

    private func recomputeSharedFileMetrics() {
        var imgBytes: Int64 = 0
        var vidBytes: Int64 = 0
        var otherBytes: Int64 = 0
        for entry in indexedFilesByPath.values {
            switch entry.category {
            case 1: imgBytes += entry.size
            case 2: vidBytes += entry.size
            default: otherBytes += entry.size
            }
        }
        if let cat1 = categorySizesById[1], cat1.bytes > imgBytes { imgBytes = cat1.bytes }
        if let cat2 = categorySizesById[2], cat2.bytes > vidBytes { vidBytes = cat2.bytes }
        let catOther = (categorySizesById[3]?.bytes ?? 0) + (categorySizesById[4]?.bytes ?? 0) + (categorySizesById[32]?.bytes ?? 0)
        if catOther > otherBytes { otherBytes = catOther }

        let totalBytes = imgBytes + vidBytes + otherBytes
        let totalCount = max(indexedFilesByPath.count, categorySizesById.values.reduce(0) { $0 + $1.count })
        guard totalBytes > 0 else { return }

        connectedDevice?.indexedMediaBytes = totalBytes
        connectedDevice?.indexedMediaCount = totalCount
        var parts: [String] = []
        if imgBytes > 0 {
            parts.append("图片 \(ByteCountFormatter.string(fromByteCount: imgBytes, countStyle: .file))")
        }
        if vidBytes > 0 {
            parts.append("视频 \(ByteCountFormatter.string(fromByteCount: vidBytes, countStyle: .file))")
        }
        if otherBytes > 0 {
            parts.append("其它 \(ByteCountFormatter.string(fromByteCount: otherBytes, countStyle: .file))")
        }
        if !parts.isEmpty {
            connectedDevice?.categoryBreakdownText = parts.joined(separator: " · ")
        }
    }

    private func handleIncomingAgentMessage(deviceId: String, msg: [String: Any]) async {
        let api = (msg["api"] as? String) ?? ""
        let sessionId = (msg["sessionId"] as? String) ?? ""
        let body = (msg["body"] as? [String: Any]) ?? [:]
        let resultObj = (msg["result"] as? [String: Any]) ?? [:]

        extractAndApplyStorageCapacity(from: msg, deviceId: deviceId)

        if api == "init.connected" {
            if let defPath = resultObj["defaultPath"] as? String, !defPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let cleanDef = defPath.trimmingCharacters(in: .whitespacesAndNewlines)
                phoneDefaultReceivePath = cleanDef.hasSuffix("/") ? String(cleanDef.dropLast()) : cleanDef
            }
            let targetId = deviceId.isEmpty ? (connectedDevice?.deviceId ?? "") : deviceId
            await triggerOShareHandshakeIfNeeded(deviceId: targetId)
            return
        }

        if api == "file.recently.list" {
            if let fileObj = resultObj["file"] as? [String: Any],
               let fPath = fileObj["filePath"] as? String, !fPath.isEmpty {
                let fName = (fileObj["fileName"] as? String) ?? (fPath as NSString).lastPathComponent
                if !fName.isEmpty {
                    recentlyReceivedPhonePathByName[fName] = fPath
                }
            }
            return
        }

        if api == "file.root" {
            extractAndApplyStorageCapacity(from: msg, deviceId: deviceId)
            return
        }

        if api == "websocket.request" {
            let method = (body["method"] as? String) ?? (resultObj["method"] as? String) ?? ""
            if method == "serverstart" {
                let portVal: Int
                if let pInt = body["port"] as? Int {
                    portVal = pInt
                } else if let pStr = body["port"] as? String, let parsed = Int(pStr) {
                    portVal = parsed
                } else if let pInt = resultObj["port"] as? Int {
                    portVal = pInt
                } else if let pStr = resultObj["port"] as? String, let parsed = Int(pStr) {
                    portVal = parsed
                } else {
                    portVal = 0
                }
                let phoneIP = (body["ip"] as? String) ?? connectedDevice?.lanIP ?? ""
                if portVal > 0, !phoneIP.isEmpty {
                    oshare.startPeerClient(remoteIP: phoneIP, remotePort: portVal, localIP: localIP)
                    statusBanner = "高速互传通道已就绪"
                }
            } else if method == "clientstart" {
                oshare.startOShareServer()
                let targetId = deviceId.isEmpty ? (connectedDevice?.deviceId ?? "") : deviceId
                let serverStartMsg: [String: Any] = [
                    "api": "websocket.request",
                    "sessionId": UUID().uuidString,
                    "header": ["clientVersion": "1.0.0", "apilevel": "1"],
                    "body": [
                        "method": "serverstart",
                        "ip": localIP,
                        "port": String(oshare.localServerPort)
                    ]
                ]
                await dspClient.sendAgentMessage(deviceId: targetId, jsonObject: serverStartMsg)
            }
            return
        }

        if api == "album.set" {
            let items = Self.extractRemoteItems(from: msg)
            recordIndexedFiles(items, defaultCategory: 1)
            return
        }

        if api == "file.category.query" {
            let items = Self.extractRemoteItems(from: msg)
            let isAlbumSet = ((resultObj["data"] as? [String: Any])?["isAlbumSet"] as? Bool) ?? false
            let resolvedCatId: Int = {
                if let mapped = categorySessionMap[sessionId] { return mapped }
                if let explicit = body["categoryId"] as? Int { return explicit }
                if let first = items.first {
                    if first.isImage { return 1 }
                    if first.isVideo { return 2 }
                    let ext = first.fileExtensionLabel.lowercased()
                    if ["mp3", "aac", "wav", "flac", "ogg", "m4a"].contains(ext) { return 3 }
                    if ["zip", "rar", "7z", "tar", "gz", "apk"].contains(ext) { return 32 }
                    return 4
                }
                return 0
            }()

            if isAlbumSet {
                let targetId = deviceId.isEmpty ? (connectedDevice?.deviceId ?? "") : deviceId
                Task {
                    for bucket in items.prefix(25) where !bucket.filePath.isEmpty {
                        try? await Task.sleep(nanoseconds: 180_000_000)
                        let albumReq = dspClient.buildRemoteListPayload(
                            remotePath: "",
                            bucketKey: bucket.filePath,
                            pageNo: 1,
                            pageSize: 5000,
                            includeThumbnails: false
                        )
                        await dspClient.sendAgentMessage(deviceId: targetId, jsonObject: albumReq)
                    }
                }
            } else if resolvedCatId > 0 {
                let catBytes = items.reduce(Int64(0)) { $0 + max(0, $1.fileSize) }
                if catBytes > 0 {
                    categorySizesById[resolvedCatId] = (bytes: catBytes, count: items.count)
                }
                recordIndexedFiles(items, defaultCategory: resolvedCatId)
            }
            return
        }

        if api == "file.list.search" {
            let items = Self.extractRemoteItems(from: msg)
            recordIndexedFiles(items)
            return
        }

        if api == "file.path.list" {
            let items = Self.extractRemoteItems(from: msg)
            let currentPathInResp = ((msg["result"] as? [String: Any])?["data"] as? [String: Any])?["currentPath"] as? String ?? currentRemotePath
            let visibleCount = showHiddenFiles ? items.count : items.filter { !$0.isHiddenItem }.count
            directoryItemCounts[currentPathInResp] = visibleCount

            if currentPathInResp == "/storage/emulated/0" {
                let visibleDirs = items.filter { $0.isDirectory && !$0.isHiddenItem }
                connectedDevice?.rootFolderCount = visibleDirs.count
                recordIndexedFiles(items)
                let scanFolders = visibleDirs
                    .map { $0.filePath }
                    .filter { !$0.hasSuffix("/Android") }
                if !scanFolders.isEmpty {
                    let targetId = deviceId.isEmpty ? (connectedDevice?.deviceId ?? "") : deviceId
                    Task {
                        for folderPath in scanFolders.prefix(18) {
                            try? await Task.sleep(nanoseconds: 220_000_000)
                            let searchPayload = dspClient.buildFileListSearchPayload(filePaths: [folderPath])
                            await dspClient.sendAgentMessage(deviceId: targetId, jsonObject: searchPayload)
                        }
                    }
                }
            }

            if currentPathInResp.isEmpty || currentPathInResp == currentRemotePath {
                isLoadingFiles = false
                remoteFiles = items
                syncLocalDownloadedFileStates()
                if let start = directoryRequestStartTime {
                    lastDirectoryLoadMs = Int(Date().timeIntervalSince(start) * 1000)
                }
                if selectedTab == .transfer {
                    statusBanner = "已加载 \(currentRemotePath) (\(displayedRemoteFiles.count) 项)"
                }
            }
            return
        }
    }

    private static func extractRemoteItems(from msg: [String: Any]) -> [RemoteFileItem] {
        var rawArray: [[String: Any]] = []
        func collectDicts(_ anyObj: Any) {
            if let arr = anyObj as? [[String: Any]] {
                rawArray.append(contentsOf: arr)
            } else if let arrAny = anyObj as? [Any] {
                for elem in arrAny { collectDicts(elem) }
            } else if let dict = anyObj as? [String: Any] {
                if dict["filePath"] != nil || dict["fileName"] != nil || dict["path"] != nil {
                    rawArray.append(dict)
                } else {
                    for val in dict.values { collectDicts(val) }
                }
            }
        }
        if let resultDict = msg["result"] as? [String: Any] {
            if let dataDict = resultDict["data"] as? [String: Any],
               let arr = dataDict["result"] as? [[String: Any]] {
                rawArray = arr
            } else if let arr = resultDict["result"] as? [[String: Any]] {
                rawArray = arr
            } else if let jsonStr = resultDict["result"] as? String,
                      let strData = jsonStr.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: strData) {
                collectDicts(parsed)
            }
        } else if let dataDict = msg["data"] as? [String: Any],
                  let arr = dataDict["result"] as? [[String: Any]] {
            rawArray = arr
        }
        return rawArray.compactMap { RemoteFileItem.fromAgentDict($0) }
    }

    private func handleIncomingDataBusEvent(_ dict: [String: Any]) {
        let eventType = (dict["event"] as? String) ?? ""
        if eventType == "on_register_app_result" {
            let appId: Int?
            if let idInt = dict["app_id"] as? Int {
                appId = idInt
            } else if let idStr = dict["app_id"] as? String, let parsed = Int(idStr) {
                appId = parsed
            } else {
                appId = nil
            }
            if let appId = appId {
                Task {
                    await dspClient.setupNotificationAndMacSubscriptions(appId: appId)
                }
            }
            return
        }
        guard eventType == "on_topic_received" else { return }
        let topicMsgStr = (dict["topic_message"] as? String) ?? (dict["msg"] as? String)
        guard let topicMsgStr = topicMsgStr,
              let topicData = topicMsgStr.data(using: .utf8),
              let msgJson = try? JSONSerialization.jsonObject(with: topicData) as? [String: Any] else {
            return
        }
        let key = (msgJson["key"] as? String) ?? ""
        if key == "switchStatus" {
            if let valStr = msgJson["value"] as? String,
               let valData = valStr.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: valData) as? [String: Any] {
                applySwitchStatusPayload(payload)
            } else if let payload = msgJson["value"] as? [String: Any] {
                applySwitchStatusPayload(payload)
            }
            return
        }
        if key == "incallui_info" {
            if let valStr = msgJson["value"] as? String,
               let valData = valStr.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: valData) as? [String: Any] {
                _ = smsService.processIncomingCallInfo(payload: payload)
            } else if let payload = msgJson["value"] as? [String: Any] {
                _ = smsService.processIncomingCallInfo(payload: payload)
            }
            return
        }
        if key == "VerificationCode" || key == "HeySynergy_Notification_Add" || key == "SYNERGY_NOTIFICATION_ADD" {
            if let valStr = msgJson["value"] as? String,
               let valData = valStr.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: valData) as? [String: Any] {
                _ = smsService.processIncomingNotification(topicKey: key, payload: payload)
            } else if let payload = msgJson["value"] as? [String: Any] {
                _ = smsService.processIncomingNotification(topicKey: key, payload: payload)
            }
        } else if key == "batteryInfo",
                  let valStr = msgJson["value"] as? String,
                  let valData = valStr.data(using: .utf8),
                  let batJson = try? JSONSerialization.jsonObject(with: valData) as? [String: Any],
                  let level = batJson["batteryLevel"] as? Int {
            let charging = ((batJson["batteryCharging"] as? Int) ?? 0) != 0
            connectedDevice?.batteryLevel = level
            connectedDevice?.isCharging = charging
        }
    }

    // MARK: - Start Discovery, Core Daemon & Non-Intrusive Health Monitor

    public func startServices() {
        dspClient.ensureCoreDaemonRunning()
        discovery.start()
        StatusBarDropController.shared.startMonitoring()

        memoryTimer?.invalidate()
        memoryTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.periodicTimerTickCount &+= 1
                self.memoryFootprintMB = max(8.0, MemoryTelemetry.currentFootprintMB())
                if self.selectedTab == .transfer {
                    self.syncLocalDownloadedFileStates()
                }
                let daemonReady = self.dspClient.isDaemonAvailable
                self.isDaemonConnected = daemonReady
                if daemonReady && !self.isDaemonInitialized {
                    await self.initializeDaemonIfPresent()
                }

                if let dev = self.connectedDevice {
                    if !self.discovery.hasValidLANIP {
                        self.handlePeerDisconnected(byUser: false)
                        return
                    }
                    if let daemonRemote = await self.dspClient.getConnectedRemoteDevice(fallbackLocalIP: self.localIP),
                       daemonRemote.device.deviceId == dev.deviceId {
                        self.consecutiveDaemonDisconnectChecks = 0
                    } else {
                        self.consecutiveDaemonDisconnectChecks += 1
                        if self.consecutiveDaemonDisconnectChecks >= 2 {
                            self.handlePeerDisconnected(byUser: false)
                            return
                        }
                    }

                    let ip = dev.lanIP
                    Task.detached(priority: .utility) {
                        let rtt = MemoryTelemetry.measureICMPLatencyMs(ip: ip)
                        await MainActor.run { [weak self] in
                            guard let self, self.connectedDevice != nil else { return }
                            if let rtt = rtt {
                                self.consecutiveICMPFailures = 0
                                self.connectedDevice?.pingLatencyMs = rtt
                            } else {
                                self.consecutiveICMPFailures += 1
                                let silenceSeconds = Date().timeIntervalSince(self.lastReceivedPhonePacketAt)
                                if self.consecutiveICMPFailures >= 3 && silenceSeconds > 8.0 {
                                    self.forceDisconnectWhenPhoneWiFiOff()
                                }
                            }
                        }
                    }
                } else {
                    guard Date() >= self.connectingLockUntil else { return }
                    await self.pollDspDaemonDevice()
                    if self.connectedDevice == nil,
                       !self.userManuallyDisconnected,
                       let candidate = self.discoveredDevices.first(where: { self.shouldAutoConnect(to: $0) }) {
                        await self.attemptAutoReconnectIfEligible(candidate)
                    }
                }
            }
        }

        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            await initializeDaemonIfPresent()
        }
    }

    private func forceDisconnectWhenPhoneWiFiOff() {
        consecutiveICMPFailures = 0
        consecutiveDaemonDisconnectChecks = 0
        connectingLockUntil = Date().addingTimeInterval(4.0)
        let currentType = connectedDevice?.connectType ?? 16
        let lostId = connectedDevice?.deviceId ?? ""
        if !lostId.isEmpty {
            discoveredDevices.removeAll { $0.deviceId == lostId }
        }
        Task {
            if dspClient.isDaemonAvailable {
                _ = try? await dspClient.stopConnection(connectType: currentType == 0 ? 16 : currentType)
            }
        }
        handlePeerDisconnected(byUser: false)
    }

    private func initializeDaemonIfPresent() async {
        guard dspClient.isDaemonAvailable else { return }
        isDaemonConnected = true
        isDaemonInitialized = true

        dspClient.startEventSubscriptionsIfNeeded()
        try? await Task.sleep(nanoseconds: 250_000_000)

        _ = try? await dspClient.initializeCore()
        try? await Task.sleep(nanoseconds: 350_000_000)

        if let daemonDevId = await dspClient.getLocalDeviceIdFromDaemon() {
            discovery.updateLocalDeviceId(daemonDevId)
        }
        await dspClient.updateScreenUnlockState()
        await dspClient.enableSenselessDiscovery(true)
        _ = try? await dspClient.setDiscoveryActive(true)
        await dspClient.probeDevices()
        await dspClient.createAgent()

        self.qrCodePayload = await dspClient.fetchQrCodeInfo(
            localIP: localIP,
            ssid: currentSSID,
            fallbackDeviceId: discovery.localDeviceId
        )

        if let reg = try? await dspClient.registerDataBusApp() {
            let appId = (reg["app_id"] as? Int) ?? Int((reg["app_id"] as? String) ?? "")
            if let appId = appId {
                await dspClient.setupNotificationAndMacSubscriptions(appId: appId)
            }
        }
        await pollDspDaemonDevice()
    }

    public func pollDspDaemonDevice() async {
        guard let result = await dspClient.getConnectedRemoteDevice(fallbackLocalIP: localIP) else { return }
        let dev = enrichDeviceWithKnownMetadata(result.device)
        if !result.localIP.isEmpty && !result.localIP.hasPrefix("*") {
            self.localIP = result.localIP
        }
        guard !discovery.isSelfAddress(dev.lanIP, serviceName: dev.deviceName, deviceId: dev.deviceId) else {
            return
        }
        upsertDiscoveredDevice(dev)
        if connectedDevice?.deviceId != dev.deviceId {
            await finalizeConnectedDevice(dev)
        }
    }

    private func finalizeConnectedDevice(_ device: OppoDevice) async {
        var connected = enrichDeviceWithKnownMetadata(device)
        connected.ssid = currentSSID
        connected.isPaired = true
        connected.lastSeen = Date()
        connectingLockUntil = .distantPast
        lastReceivedPhonePacketAt = Date()
        consecutiveICMPFailures = 0
        consecutiveDaemonDisconnectChecks = 0
        userManuallyDisconnected = false
        UserDefaults.standard.set(false, forKey: manualDisconnectDefaultsKey)
        rememberPairedDevice(connected)
        self.connectedDevice = connected
        self.connectionState = .connected
        self.statusBanner = "已连接 \(connected.deviceName)"

        let ip = connected.lanIP
        let devId = connected.deviceId
        Task.detached(priority: .utility) {
            let rtt = MemoryTelemetry.measureICMPLatencyMs(ip: ip)
            let adbCap = MemoryTelemetry.queryADBStorageCapacity(ip: ip)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let rtt = rtt {
                    self.connectedDevice?.pingLatencyMs = rtt
                }
                if let adbCap = adbCap {
                    self.lastKnownStorageByDeviceId[devId] = adbCap
                    self.connectedDevice?.storageTotalBytes = adbCap.total
                    self.connectedDevice?.storageFreeBytes = adbCap.free
                }
            }
        }

        await dspClient.updateScreenUnlockState()
        await dspClient.createAgent()
        await dspClient.connectAgent(connectType: connected.connectType)

        if let reg = try? await dspClient.registerDataBusApp() {
            let appId = (reg["app_id"] as? Int) ?? Int((reg["app_id"] as? String) ?? "") ?? 12
            await dspClient.setupNotificationAndMacSubscriptions(appId: appId)
        }

        await triggerOShareHandshakeIfNeeded(deviceId: connected.deviceId)
    }

    private func upsertDiscoveredDevice(_ device: OppoDevice) {
        guard !discovery.isSelfAddress(device.lanIP, serviceName: device.deviceName, deviceId: device.deviceId) else {
            return
        }
        let enriched = enrichDeviceWithKnownMetadata(device)
        if let idx = discoveredDevices.firstIndex(where: { $0.deviceId == enriched.deviceId || $0.lanIP == enriched.lanIP }) {
            let existing = discoveredDevices[idx]
            let finalName = enriched.hasSpecificModelName ? enriched.deviceName : (existing.hasSpecificModelName ? existing.deviceName : enriched.deviceName)
            let useExistingId = (enriched.deviceId.hasPrefix("oppo-") || enriched.deviceId == LanSdpDiscovery.deterministicDeviceId(forIP: enriched.lanIP))
                && !existing.deviceId.hasPrefix("oppo-")
                && existing.deviceId != LanSdpDiscovery.deterministicDeviceId(forIP: existing.lanIP)
            let finalId = useExistingId ? existing.deviceId : enriched.deviceId
            let merged = OppoDevice(
                deviceId: finalId,
                deviceName: finalName,
                lanIP: (enriched.lanIP.isEmpty || enriched.lanIP == "同局域网") ? existing.lanIP : enriched.lanIP,
                port: enriched.port,
                connectType: enriched.connectType != 0 ? enriched.connectType : existing.connectType,
                ssid: currentSSID,
                batteryLevel: enriched.batteryLevel ?? existing.batteryLevel,
                isCharging: enriched.isCharging || existing.isCharging,
                systemVersion: enriched.systemVersion,
                phoneModel: enriched.phoneModel ?? existing.phoneModel,
                osVersionName: enriched.osVersionName ?? existing.osVersionName,
                screenResolution: enriched.screenResolution ?? existing.screenResolution,
                storageSummary: enriched.storageSummary,
                storageTotalBytes: enriched.storageTotalBytes ?? existing.storageTotalBytes,
                storageFreeBytes: enriched.storageFreeBytes ?? existing.storageFreeBytes,
                indexedMediaBytes: enriched.indexedMediaBytes ?? existing.indexedMediaBytes,
                indexedMediaCount: enriched.indexedMediaCount ?? existing.indexedMediaCount,
                categoryBreakdownText: enriched.categoryBreakdownText ?? existing.categoryBreakdownText,
                rootFolderCount: enriched.rootFolderCount ?? existing.rootFolderCount,
                pingLatencyMs: enriched.pingLatencyMs ?? existing.pingLatencyMs,
                isPaired: pairedDeviceIds.contains(finalId) || existing.isPaired,
                isSameAccount: enriched.isSameAccount || existing.isSameAccount,
                discoverySource: enriched.discoverySource == .dspDaemon ? .dspDaemon : existing.discoverySource
            )
            discoveredDevices[idx] = merged
        } else {
            discoveredDevices.insert(enriched, at: 0)
        }
        discoveredDevices.sort { lhs, rhs in
            if (lhs.deviceId == lastConnectedDeviceId) != (rhs.deviceId == lastConnectedDeviceId) {
                return lhs.deviceId == lastConnectedDeviceId
            }
            if lhs.isPaired != rhs.isPaired {
                return lhs.isPaired && !rhs.isPaired
            }
            return lhs.deviceName < rhs.deviceName
        }
    }

    // MARK: - Device Connection Actions

    public func triggerManualScan() {
        if connectedDevice == nil {
            connectionState = .scanning
        }
        connectingLockUntil = .distantPast
        seedRecentDeviceAndBatteryStateFromDaemonLog()
        discovery.triggerImmediateScan()
        statusBanner = "正在搜索同一 Wi-Fi 下的手机..."
        Task {
            if !dspClient.isDaemonAvailable {
                dspClient.ensureCoreDaemonRunning()
                try? await Task.sleep(nanoseconds: 900_000_000)
            }
            if dspClient.isDaemonAvailable && !isDaemonInitialized {
                await initializeDaemonIfPresent()
            } else if dspClient.isDaemonAvailable {
                if let daemonDevId = await dspClient.getLocalDeviceIdFromDaemon() {
                    discovery.updateLocalDeviceId(daemonDevId)
                }
                await dspClient.updateScreenUnlockState()
                _ = try? await dspClient.setDiscoveryActive(true)
                await dspClient.probeDevices()
            }
            self.qrCodePayload = await dspClient.fetchQrCodeInfo(
                localIP: localIP,
                ssid: currentSSID,
                fallbackDeviceId: discovery.localDeviceId
            )
            await pollDspDaemonDevice()
        }
    }

    public func connectByIP(_ ipInput: String) {
        let trimmed = ipInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if discovery.isSelfAddress(trimmed) {
            statusBanner = "该 IP 为当前 Mac 本机地址，请输入手机的局域网 IP"
            return
        }
        userManuallyDisconnected = false
        UserDefaults.standard.set(false, forKey: manualDisconnectDefaultsKey)
        connectionState = .connecting
        statusBanner = "正在尝试连接 \(trimmed)..."
        let knownName = knownDeviceNameByIP[trimmed]
        discovery.probeDirectPeer(ip: trimmed, port: 10152, knownName: knownName) { [weak self] dev in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let dev = dev {
                    let enriched = self.enrichDeviceWithKnownMetadata(dev)
                    self.upsertDiscoveredDevice(enriched)
                    await self.connect(to: enriched)
                } else {
                    self.connectionState = self.connectedDevice == nil ? .disconnected : .connected
                    self.statusBanner = "未在 \(trimmed) 检测到在线的手机"
                }
            }
        }
    }

    public func connect(to device: OppoDevice) async {
        guard !discovery.isSelfAddress(device.lanIP, serviceName: device.deviceName, deviceId: device.deviceId) else {
            return
        }
        userManuallyDisconnected = false
        UserDefaults.standard.set(false, forKey: manualDisconnectDefaultsKey)
        let enriched = enrichDeviceWithKnownMetadata(device)
        rememberPairedDevice(enriched)
        await requestDspConnection(to: enriched)
    }

    private func requestDspConnection(to device: OppoDevice) async {
        connectingLockUntil = Date().addingTimeInterval(25.0)
        lastAutoConnectAttemptByDevice[device.deviceId] = Date()
        connectionState = .connecting
        statusBanner = "正在向 \(device.deviceName) 发起连接..."

        if !dspClient.isDaemonAvailable {
            dspClient.ensureCoreDaemonRunning()
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if dspClient.isDaemonAvailable { break }
            }
            if dspClient.isDaemonAvailable && !isDaemonInitialized {
                await initializeDaemonIfPresent()
            }
        }

        guard dspClient.isDaemonAvailable else {
            connectingLockUntil = .distantPast
            connectionState = .disconnected
            statusBanner = "互联守护进程正在启动，请稍后重试"
            return
        }

        let latestDevice = discoveredDevices.first(where: { $0.lanIP == device.lanIP || $0.deviceId == device.deviceId }) ?? device
        _ = try? await dspClient.requestConnection(to: latestDevice)
        statusBanner = "已向 \(latestDevice.deviceName) 发送连接请求，请在手机弹窗中点击「连接」"

        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if connectedDevice != nil {
                return
            }
            await pollDspDaemonDevice()
            if connectedDevice != nil {
                return
            }
        }

        if connectedDevice == nil {
            connectingLockUntil = .distantPast
            connectionState = .scanning
            statusBanner = "请在手机弹窗中确认连接，或使用手机扫描二维码"
        }
    }

    public func disconnect() {
        userManuallyDisconnected = true
        UserDefaults.standard.set(true, forKey: manualDisconnectDefaultsKey)
        connectingLockUntil = Date().addingTimeInterval(5.0)
        let currentType = connectedDevice?.connectType ?? 16
        Task {
            if dspClient.isDaemonAvailable {
                _ = try? await dspClient.stopConnection(connectType: currentType == 0 ? 16 : currentType)
            }
        }
        handlePeerDisconnected(byUser: true)
    }

    private func handlePeerDisconnected(byUser: Bool) {
        connectedDevice = nil
        activeIncomingCall = nil
        consecutiveICMPFailures = 0
        consecutiveDaemonDisconnectChecks = 0
        connectionState = byUser ? .disconnected : .scanning
        remoteFiles = []
        selectedFileIds.removeAll()
        isLoadingFiles = false
        statusBanner = byUser ? "已手动断开连接" : "手机已断开或离开当前 Wi-Fi，恢复后将自动重连"
    }

    // MARK: - On-Demand Phone File Manager Browsing, Delete & Download Feedback

    public func refreshRemoteDirectory(_ path: String) {
        let normalized = path.isEmpty ? "/storage/emulated/0" : path
        currentRemotePath = normalized
        selectedFileIds.removeAll()
        syncLocalDownloadedFileStates()
        guard let dev = connectedDevice else {
            remoteFiles = []
            isLoadingFiles = false
            return
        }
        isLoadingFiles = true
        directoryRequestStartTime = Date()
        let payload = dspClient.buildRemoteListPayload(
            remotePath: normalized,
            bucketKey: nil,
            pageNo: 1,
            pageSize: 500,
            includeThumbnails: false
        )
        Task {
            await dspClient.sendAgentMessage(deviceId: dev.deviceId, jsonObject: payload)
        }
    }

    public func navigateToParentRemoteDirectory() {
        let root = "/storage/emulated/0"
        guard currentRemotePath != root, currentRemotePath.count > root.count else {
            refreshRemoteDirectory(root)
            return
        }
        let parent = (currentRemotePath as NSString).deletingLastPathComponent
        let target = parent.hasPrefix(root) ? parent : root
        refreshRemoteDirectory(target)
    }

    public func toggleFileSelection(_ item: RemoteFileItem) {
        guard !item.isDirectory else { return }
        if selectedFileIds.contains(item.id) {
            selectedFileIds.remove(item.id)
        } else {
            selectedFileIds.insert(item.id)
        }
    }

    public func downloadSelectedFiles() {
        let selectedItems = displayedRemoteFiles.filter { selectedFileIds.contains($0.id) && !$0.isDirectory }
        guard !selectedItems.isEmpty else { return }
        for item in selectedItems {
            downloadRemoteItem(item)
        }
        selectedFileIds.removeAll()
    }

    public func requestDeleteRemoteItem(_ item: RemoteFileItem) {
        pendingDeleteItems = [item]
        showDeleteConfirmation = true
    }

    public func requestDeleteSelectedRemoteItems() {
        let selectedItems = displayedRemoteFiles.filter { selectedFileIds.contains($0.id) }
        guard !selectedItems.isEmpty else { return }
        pendingDeleteItems = selectedItems
        showDeleteConfirmation = true
    }

    public func cancelDeletePendingItems() {
        pendingDeleteItems = []
        showDeleteConfirmation = false
    }

    public func confirmDeletePendingItems() {
        let itemsToDelete = pendingDeleteItems
        pendingDeleteItems = []
        showDeleteConfirmation = false
        guard !itemsToDelete.isEmpty else { return }
        if itemsToDelete.count == 1, let single = itemsToDelete.first {
            deleteRemoteItem(single)
        } else {
            deleteRemoteItemsBatch(itemsToDelete)
        }
    }

    public func deleteRemoteItem(_ item: RemoteFileItem) {
        guard let dev = connectedDevice else { return }
        let targetPath = item.filePath
        guard !targetPath.isEmpty else { return }

        remoteFiles.removeAll { $0.id == item.id || $0.filePath == targetPath }
        selectedFileIds.remove(item.id)
        indexedFilesByPath.removeValue(forKey: targetPath)
        recomputeSharedFileMetrics()
        statusBanner = "已删除手机文件：\(item.fileName)"

        let payload = dspClient.buildDeleteFilesPayload(filePaths: [targetPath])
        let currentDir = currentRemotePath
        Task {
            await dspClient.sendAgentMessage(deviceId: dev.deviceId, jsonObject: payload)
            try? await Task.sleep(nanoseconds: 650_000_000)
            await MainActor.run { [weak self] in
                guard let self, self.currentRemotePath == currentDir else { return }
                self.refreshRemoteDirectory(currentDir)
            }
        }
    }

    public func deleteSelectedRemoteItems() {
        let selectedItems = displayedRemoteFiles.filter { selectedFileIds.contains($0.id) }
        deleteRemoteItemsBatch(selectedItems)
    }

    private func deleteRemoteItemsBatch(_ items: [RemoteFileItem]) {
        guard let dev = connectedDevice else { return }
        guard !items.isEmpty else { return }
        let paths = items.map { $0.filePath }.filter { !$0.isEmpty }
        guard !paths.isEmpty else { return }

        let removedIds = Set(items.map { $0.id })
        remoteFiles.removeAll { removedIds.contains($0.id) }
        for p in paths { indexedFilesByPath.removeValue(forKey: p) }
        recomputeSharedFileMetrics()
        selectedFileIds.removeAll()
        statusBanner = "已删除 \(paths.count) 个手机文件"

        let payload = dspClient.buildDeleteFilesPayload(filePaths: paths)
        let currentDir = currentRemotePath
        Task {
            await dspClient.sendAgentMessage(deviceId: dev.deviceId, jsonObject: payload)
            try? await Task.sleep(nanoseconds: 650_000_000)
            await MainActor.run { [weak self] in
                guard let self, self.currentRemotePath == currentDir else { return }
                self.refreshRemoteDirectory(currentDir)
            }
        }
    }

    public func clearTransferTasks() {
        transferTasks.removeAll { $0.state != .transferring }
        if transferTasks.isEmpty {
            showTransferPopover = false
        }
    }

    public func copyRemotePathToClipboard(_ path: String) {
        smsService.copyToClipboard(path)
        statusBanner = "已复制路径：\(path)"
    }

    // MARK: - Bidirectional File Transfer Actions & Custom Receive Directory

    /// Sends local files from Mac to Phone.
    /// - When triggered from Menu Bar or Floating Status Bar Drop Window: `explicitTargetDirectory` is `/storage/emulated/0/Download/ColorDrop`.
    /// - When triggered from Main Window's Transfer tab (drag-and-drop or upload button): `explicitTargetDirectory` is `currentRemotePath`.
    public func sendLocalFilesToPhone(urls: [URL], explicitTargetDirectory: String? = nil) {
        guard !urls.isEmpty else { return }
        guard let target = connectedDevice else {
            statusBanner = "请先连接手机后再发送文件"
            selectedTab = .connect
            return
        }
        let resolvedTarget = (explicitTargetDirectory?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? explicitTargetDirectory!
            : (currentRemotePath.isEmpty ? "/storage/emulated/0" : currentRemotePath)
        let targetDir = resolvedTarget.hasSuffix("/") && resolvedTarget.count > 1
            ? String(resolvedTarget.dropLast())
            : resolvedTarget

        Task {
            await sendOShareHandshakeMessages(deviceId: target.deviceId)
            if targetDir == Self.menuBarDefaultRemoteDirectory {
                let mkdirPayload = dspClient.buildCreateFolderPayload(
                    parentPath: "/storage/emulated/0/Download",
                    folderName: "ColorDrop"
                )
                await dspClient.sendAgentMessage(deviceId: target.deviceId, jsonObject: mkdirPayload)
            }
            let tasks = oshare.sendFilesToPhone(
                urls: urls,
                targetDevice: target,
                localIP: localIP,
                targetRemoteDirectory: targetDir
            )
            for t in tasks {
                uploadTargetDirByTaskId[t.taskId] = targetDir
            }
            transferTasks.insert(contentsOf: tasks, at: 0)
            let dirDisplayName: String = {
                if targetDir == Self.menuBarDefaultRemoteDirectory {
                    return "Download/ColorDrop"
                }
                if targetDir == "/storage/emulated/0" {
                    return "手机存储根目录"
                }
                return (targetDir as NSString).lastPathComponent
            }()
            statusBanner = "正在上传 \(urls.count) 个文件至「\(dirDisplayName)」..."
        }
    }

    /// Triggered from the Main Window's Transfer tab: uploads to the currently opened remote directory (`currentRemotePath`).
    public func pickAndSendFilesToPhone() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "上传"
        panel.message = "选择要上传到当前手机目录 (\(currentRemotePath)) 的文件"
        if panel.runModal() == .OK {
            sendLocalFilesToPhone(urls: panel.urls, explicitTargetDirectory: currentRemotePath)
        }
    }

    /// Triggered from the Menu Bar popover (`发送文件`): always uploads to `/storage/emulated/0/Download/ColorDrop`.
    public func pickAndSendFilesFromMenuBar() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "发送"
        panel.message = "选择要发送到手机 Download/ColorDrop 文件夹的文件"
        if panel.runModal() == .OK {
            sendLocalFilesToPhone(
                urls: panel.urls,
                explicitTargetDirectory: Self.menuBarDefaultRemoteDirectory
            )
        }
    }

    public func downloadRemoteItem(_ item: RemoteFileItem) {
        if item.isDirectory {
            refreshRemoteDirectory(item.filePath)
            selectedTab = .transfer
            return
        }
        guard let target = connectedDevice else {
            statusBanner = "请先连接手机后再下载文件"
            return
        }
        if fileDownloadStates[item.filePath] == .transferring {
            return
        }
        fileDownloadStates[item.filePath] = .transferring
        fileDownloadProgress[item.filePath] = 0.08

        let task = oshare.downloadRemoteItemToMac(item: item, targetDevice: target, localIP: localIP)
        transferTasks.insert(task, at: 0)
        statusBanner = "正在下载 \(item.fileName)..."

        let pathKey = item.filePath
        let expectedLocalFile = oshare.receiveDirectory.appendingPathComponent(item.fileName)
        Task { @MainActor [weak self] in
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self else { return }
                if self.fileDownloadStates[pathKey] == .success { break }
                if FileManager.default.fileExists(atPath: expectedLocalFile.path) {
                    self.fileDownloadStates[pathKey] = .success
                    self.fileDownloadProgress[pathKey] = 1.0
                    self.localFilesRevision &+= 1
                    self.statusBanner = "已下载 \(item.fileName) 至「\(self.oshare.receiveDirectory.lastPathComponent)」"
                    break
                }
            }
            if let self, self.fileDownloadStates[pathKey] == .transferring {
                if FileManager.default.fileExists(atPath: expectedLocalFile.path) {
                    self.fileDownloadStates[pathKey] = .success
                    self.fileDownloadProgress[pathKey] = 1.0
                } else {
                    self.fileDownloadStates.removeValue(forKey: pathKey)
                }
                self.localFilesRevision &+= 1
            }
        }
    }

    public func openReceiveDirectoryInFinder() {
        NSWorkspace.shared.open(oshare.receiveDirectory)
    }

    public func chooseCustomReceiveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = oshare.receiveDirectory
        panel.prompt = "选择保存目录"
        panel.message = "选择手机文件下载与接收的保存文件夹"
        if panel.runModal() == .OK, let pickedURL = panel.url {
            oshare.updateReceiveDirectory(pickedURL)
            receiveDirectoryPath = pickedURL.path
            syncLocalDownloadedFileStates()
            statusBanner = "接收目录已更新为：\(pickedURL.path)"
        }
    }

    // MARK: - Message & Verification Code Actions

    public func markAllMessagesRead() {
        var changed = false
        for idx in smsMessages.indices where !smsMessages[idx].isRead {
            smsMessages[idx].isRead = true
            changed = true
        }
        if changed {
            saveMessageHistory()
        }
    }

    public func copyVerificationCode(_ code: String, messageId: String? = nil) {
        smsService.copyToClipboard(code)
        lastCopiedCode = code
        if let mid = messageId {
            copiedMessageId = mid
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if self?.copiedMessageId == mid {
                    self?.copiedMessageId = nil
                }
            }
        }
        statusBanner = "验证码 \(code) 已复制"
    }

    public func copySMSCode(_ code: String) {
        copyVerificationCode(code, messageId: nil)
    }

    public func toggleMessageContentMode(_ messageId: String) {
        if expandedMessageIds.contains(messageId) {
            expandedMessageIds.remove(messageId)
        } else {
            expandedMessageIds.insert(messageId)
        }
    }

    public func clearAllMessages() {
        smsMessages.removeAll()
        expandedMessageIds.removeAll()
        try? FileManager.default.removeItem(atPath: messageHistoryFilePath)
    }

    public func hangupCurrentCall() {
        guard let call = activeIncomingCall else { return }
        activeIncomingCall = nil
        statusBanner = "已挂断 \(call.displayTitle) 的来电"
        Task {
            await dspClient.hangupIncomingCall(callId: call.id, phoneNumber: call.number)
        }
    }
}
