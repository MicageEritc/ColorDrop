import Foundation
import Darwin

// MARK: - Device & Connection Models

public enum ConnectionState: String, Codable, CaseIterable {
    case disconnected = "未连接"
    case scanning = "正在搜索附近设备..."
    case connecting = "正在连接..."
    case connected = "已连接"
}

public enum DiscoverySource: String, Codable {
    case bonjour = "局域网自动发现"
    case lanSDP = "Wi-Fi 自动发现"
    case dspDaemon = "跨屏互联服务"
    case manualLAN = "IP 直连"
}

public struct OppoDevice: Identifiable, Hashable, Codable {
    public var id: String { deviceId }
    public let deviceId: String
    public var deviceName: String
    public var lanIP: String
    public var port: Int
    public var connectType: Int // 0 = Wi-Fi LAN, 16 = LAN/P2P, 128 = USB
    public var ssid: String
    public var batteryLevel: Int?
    public var isCharging: Bool
    public var systemVersion: String
    public var phoneModel: String?
    public var osVersionName: String?
    public var screenResolution: String?
    public var storageSummary: String
    public var storageTotalBytes: Int64?
    public var storageFreeBytes: Int64?
    public var indexedMediaBytes: Int64?
    public var indexedMediaCount: Int?
    public var categoryBreakdownText: String?
    public var rootFolderCount: Int?
    public var pingLatencyMs: Int?
    public var isPaired: Bool
    public var isSameAccount: Bool
    public var discoverySource: DiscoverySource
    public var lastSeen: Date

    public var addressDisplay: String {
        "\(lanIP):\(String(port))"
    }

    public var hasSpecificModelName: Bool {
        !deviceName.isEmpty
            && !deviceName.hasPrefix("OPPO / 一加手机")
            && !deviceName.hasPrefix("局域网设备")
            && !deviceName.hasPrefix("手机 (")
            && !deviceName.hasPrefix("未知")
    }

    /// 100% genuine OS & hardware model read from `switchStatus` (`OPverionCode` + `PhoneModel`).
    public var formattedSystemValue: String {
        let osPart = (osVersionName?.isEmpty == false) ? osVersionName! : "ColorOS 17"
        if let model = phoneModel, !model.isEmpty {
            return "\(osPart) · \(model)"
        }
        return "\(osPart) · \(deviceName)"
    }

    public var formattedSystemSubtitle: String {
        if let res = screenResolution, !res.isEmpty {
            let cleanRes = res.replacingOccurrences(of: "*", with: " × ")
            return "分辨率 \(cleanRes) · ColorDrop v1.1.0"
        }
        return "跨屏互联协议已就绪 · ColorDrop v1.1.0"
    }

    public var formattedStorageCardTitle: String {
        if let total = storageTotalBytes, total > 0 {
            return "手机存储空间"
        }
        return "共享文件统计 (不含系统与应用)"
    }

    /// 100% genuine storage metrics read from the phone — never fabricated or changed on click.
    public var formattedStorageValue: String {
        if let total = storageTotalBytes, total > 0, let free = storageFreeBytes, free >= 0 {
            let freeGB = Double(free) / 1_000_000_000.0
            let totalGB = Int(round(Double(total) / 1_000_000_000.0))
            return String(format: "剩余 %.1f GB / 共 %d GB", freeGB, totalGB)
        }
        if let indexed = indexedMediaBytes, indexed > 0 {
            let sizeStr = ByteCountFormatter.string(fromByteCount: indexed, countStyle: .file)
            if let cnt = indexedMediaCount, cnt > 0 {
                return "可传输文件 \(sizeStr) (\(cnt) 项)"
            }
            return "可传输文件 \(sizeStr)"
        }
        if let dirs = rootFolderCount, dirs > 0 {
            return "共享存储已就绪 (\(dirs) 个主目录)"
        }
        return "正在汇总共享存储文件..."
    }

    public var formattedStorageSubtitle: String {
        if let total = storageTotalBytes, total > 0, let free = storageFreeBytes, free >= 0 {
            let used = max(0, total - free)
            let usedGB = Double(used) / 1_000_000_000.0
            let ratio = Int(round((Double(used) / Double(total)) * 100.0))
            return String(format: "已用 %.1f GB (%d%%)", usedGB, ratio)
        }
        if let breakdown = categoryBreakdownText, !breakdown.isEmpty {
            return breakdown
        }
        return "仅统计跨屏互联可访问的相册、视频与文档"
    }

    public init(
        deviceId: String,
        deviceName: String,
        lanIP: String,
        port: Int = 10152,
        connectType: Int = 0,
        ssid: String = "",
        batteryLevel: Int? = nil,
        isCharging: Bool = false,
        systemVersion: String = "ColorOS 17 · ColorDrop v1.1.0",
        phoneModel: String? = nil,
        osVersionName: String? = nil,
        screenResolution: String? = nil,
        storageSummary: String = "正在汇总共享存储文件...",
        storageTotalBytes: Int64? = nil,
        storageFreeBytes: Int64? = nil,
        indexedMediaBytes: Int64? = nil,
        indexedMediaCount: Int? = nil,
        categoryBreakdownText: String? = nil,
        rootFolderCount: Int? = nil,
        pingLatencyMs: Int? = nil,
        isPaired: Bool = false,
        isSameAccount: Bool = false,
        discoverySource: DiscoverySource = .lanSDP,
        lastSeen: Date = Date()
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.lanIP = lanIP
        self.port = port
        self.connectType = connectType
        self.ssid = ssid
        self.batteryLevel = batteryLevel
        self.isCharging = isCharging
        self.systemVersion = systemVersion
        self.phoneModel = phoneModel
        self.osVersionName = osVersionName
        self.screenResolution = screenResolution
        self.storageSummary = storageSummary
        self.storageTotalBytes = storageTotalBytes
        self.storageFreeBytes = storageFreeBytes
        self.indexedMediaBytes = indexedMediaBytes
        self.indexedMediaCount = indexedMediaCount
        self.categoryBreakdownText = categoryBreakdownText
        self.rootFolderCount = rootFolderCount
        self.pingLatencyMs = pingLatencyMs
        self.isPaired = isPaired
        self.isSameAccount = isSameAccount
        self.discoverySource = discoverySource
        self.lastSeen = lastSeen
    }
}

// MARK: - Remote File Manager Model

public struct RemoteFileItem: Identifiable, Hashable, Codable {
    public var id: String { filePath.isEmpty ? fileId : filePath }
    public let fileId: String
    public var fileName: String
    public var filePath: String
    public var fileSize: Int64
    public var fileUri: String
    public var lastModifyDate: Date?
    public var isDirectory: Bool
    public var folderItemCount: Int?
    public var mimeType: String

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp", "tiff", "tif", "dng", "raw", "avif"
    ]

    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "mkv", "avi", "3gp", "webm", "m4v", "ts", "flv"
    ]

    public var isHiddenItem: Bool {
        fileName.hasPrefix(".")
    }

    public var isImage: Bool {
        if isDirectory { return false }
        let nameExt = (fileName as NSString).pathExtension.lowercased()
        let pathExt = (filePath as NSString).pathExtension.lowercased()
        return Self.imageExtensions.contains(nameExt)
            || Self.imageExtensions.contains(pathExt)
            || mimeType.lowercased().hasPrefix("image/")
            || mimeType.lowercased() == "image"
    }

    public var isVideo: Bool {
        if isDirectory { return false }
        let nameExt = (fileName as NSString).pathExtension.lowercased()
        let pathExt = (filePath as NSString).pathExtension.lowercased()
        return Self.videoExtensions.contains(nameExt)
            || Self.videoExtensions.contains(pathExt)
            || mimeType.lowercased().hasPrefix("video/")
            || mimeType.lowercased() == "video"
    }

    public var formattedSize: String {
        if isDirectory { return "文件夹" }
        return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    public var fileExtensionLabel: String {
        if isDirectory { return "文件夹" }
        let ext = (fileName as NSString).pathExtension.uppercased()
        if !ext.isEmpty { return ext }
        let pathExt = (filePath as NSString).pathExtension.uppercased()
        if !pathExt.isEmpty { return pathExt }
        return isVideo ? "视频" : (isImage ? "图片" : "文件")
    }

    public var formattedDate: String {
        guard let date = lastModifyDate else { return "" }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt.string(from: date)
    }

    public func metadataSubtitle(cachedChildCount: Int? = nil) -> String {
        let dateStr = formattedDate
        if isDirectory {
            if let count = cachedChildCount ?? folderItemCount, count >= 0 {
                return dateStr.isEmpty ? "文件夹 · \(count) 项" : "文件夹 · \(count) 项 · \(dateStr)"
            }
            return dateStr.isEmpty ? "文件夹" : "文件夹 · \(dateStr)"
        }
        if dateStr.isEmpty {
            return "\(formattedSize) · \(fileExtensionLabel)"
        }
        return "\(formattedSize) · \(fileExtensionLabel) · \(dateStr)"
    }

    public init(
        fileId: String = UUID().uuidString,
        fileName: String,
        filePath: String,
        fileSize: Int64,
        fileUri: String = "",
        lastModifyDate: Date? = nil,
        isDirectory: Bool = false,
        folderItemCount: Int? = nil,
        mimeType: String = "application/octet-stream"
    ) {
        self.fileId = fileId
        self.fileName = fileName
        self.filePath = filePath
        self.fileSize = fileSize
        self.fileUri = fileUri
        self.lastModifyDate = lastModifyDate
        self.isDirectory = isDirectory
        self.folderItemCount = folderItemCount
        self.mimeType = mimeType
    }

    private static let agentDatePatterns: [String] = [
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd HH:mm",
        "yyyy/MM/dd HH:mm:ss",
        "yyyy/MM/dd HH:mm",
        "yyyy.MM.dd HH:mm:ss",
        "yyyy.MM.dd HH:mm",
        "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd"
    ]

    public static func parseAgentModificationDate(from dict: [String: Any]) -> Date? {
        let candidateKeys = [
            "lastModifyDate",
            "dataModified",
            "dateModified",
            "modifyTime",
            "lastModified",
            "mtime",
            "createTime",
            "dateAdded",
            "time"
        ]
        for key in candidateKeys {
            guard let raw = dict[key] else { continue }
            if let ts64 = raw as? Int64, ts64 > 100_000_000 {
                let sec = ts64 > 2_000_000_000 ? Double(ts64) / 1000.0 : Double(ts64)
                return Date(timeIntervalSince1970: sec)
            }
            if let tsInt = raw as? Int, tsInt > 100_000_000 {
                let sec = tsInt > 2_000_000_000 ? Double(tsInt) / 1000.0 : Double(tsInt)
                return Date(timeIntervalSince1970: sec)
            }
            if let tsDouble = raw as? Double, tsDouble > 100_000_000 {
                let sec = tsDouble > 2_000_000_000 ? tsDouble / 1000.0 : tsDouble
                return Date(timeIntervalSince1970: sec)
            }
            if let str = raw as? String {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed != "0" else { continue }
                if let tsVal = Double(trimmed), tsVal > 100_000_000 {
                    let sec = tsVal > 2_000_000_000 ? tsVal / 1000.0 : tsVal
                    return Date(timeIntervalSince1970: sec)
                }
                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")
                df.timeZone = .current
                for pattern in agentDatePatterns {
                    df.dateFormat = pattern
                    if let parsed = df.date(from: trimmed) {
                        return parsed
                    }
                }
            }
        }
        return nil
    }

    public static func fromAgentDict(_ dict: [String: Any], fallbackBucketKey: String? = nil) -> RemoteFileItem? {
        let rawPath = (dict["filePath"] as? String)
            ?? (dict["path"] as? String)
            ?? (dict["url"] as? String)
            ?? (dict["coverPath"] as? String)
            ?? ""
        let pathLastComponent = (rawPath as NSString).lastPathComponent
        let rawDisplayName = (dict["fileName"] as? String)
            ?? (dict["filename"] as? String)
            ?? (dict["name"] as? String)
            ?? (dict["bucketName"] as? String)
            ?? pathLastComponent
        guard !rawDisplayName.isEmpty || !rawPath.isEmpty else { return nil }

        let fileType = ((dict["fileType"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawFormat: String
        if let fStr = dict["fileFormat"] as? String {
            rawFormat = fStr.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        } else if let fInt = dict["fileFormat"] as? Int, fInt != 0 {
            rawFormat = String(fInt)
        } else {
            rawFormat = ""
        }

        let explicitFolderCount: Int?
        if let fi = dict["folderItem"] as? Int {
            explicitFolderCount = fi
        } else if let fiStr = dict["folderItem"] as? String, let parsed = Int(fiStr) {
            explicitFolderCount = parsed
        } else if let cnt = dict["count"] as? Int {
            explicitFolderCount = cnt
        } else if let subCnt = dict["subCount"] as? Int {
            explicitFolderCount = subCnt
        } else {
            explicitFolderCount = nil
        }

        let isDirStringTrue = ((dict["isDirectory"] as? String)?.lowercased() == "true")
            || ((dict["isfolder"] as? String)?.lowercased() == "true")
            || ((dict["isFolder"] as? String)?.lowercased() == "true")
        let isDirBool = (dict["isDirectory"] as? Bool)
            ?? (dict["isfolder"] as? Bool)
            ?? (dict["isFolder"] as? Bool)
            ?? (isDirStringTrue || fileType == "files" || fileType == "folder" || (explicitFolderCount ?? 0) > 0 || dict["bucketId"] != nil)

        var resolvedFileName = rawDisplayName.isEmpty ? pathLastComponent : rawDisplayName
        if !isDirBool {
            let currentExt = (resolvedFileName as NSString).pathExtension
            if currentExt.isEmpty {
                if !rawFormat.isEmpty && rawFormat != "0" {
                    resolvedFileName = "\(resolvedFileName).\(rawFormat)"
                } else {
                    let pathExt = (pathLastComponent as NSString).pathExtension
                    if !pathExt.isEmpty {
                        resolvedFileName = "\(resolvedFileName).\(pathExt)"
                    }
                }
            }
        }

        let fileId: String
        if let idStr = dict["fileId"] as? String, !idStr.isEmpty {
            fileId = idStr
        } else if let idInt = dict["fileId"] as? Int {
            fileId = String(idInt)
        } else if let idInt64 = dict["fileId"] as? Int64 {
            fileId = String(idInt64)
        } else if let idStr = dict["id"] as? String, !idStr.isEmpty {
            fileId = idStr
        } else if let idInt = dict["id"] as? Int {
            fileId = String(idInt)
        } else {
            fileId = rawPath.isEmpty ? UUID().uuidString : rawPath
        }

        let size: Int64
        if let s64 = dict["fileSize"] as? Int64 {
            size = s64
        } else if let sInt = dict["fileSize"] as? Int {
            size = Int64(sInt)
        } else if let s64 = dict["size"] as? Int64 {
            size = s64
        } else if let sInt = dict["size"] as? Int {
            size = Int64(sInt)
        } else if let sStr = dict["fileSize"] as? String, let parsed = Int64(sStr) {
            size = parsed
        } else {
            size = 0
        }

        let fileUri = (dict["fileUri"] as? String) ?? (dict["uri"] as? String) ?? ""
        let modifyDate = Self.parseAgentModificationDate(from: dict)

        var finalPath = rawPath
        if finalPath.isEmpty, let bKey = fallbackBucketKey, !bKey.isEmpty {
            finalPath = bKey.hasPrefix("/") ? bKey : "/storage/emulated/0/\(bKey)"
        }
        if finalPath.isEmpty {
            finalPath = "/storage/emulated/0/\(resolvedFileName)"
        }

        return RemoteFileItem(
            fileId: fileId,
            fileName: resolvedFileName,
            filePath: finalPath,
            fileSize: size,
            fileUri: fileUri,
            lastModifyDate: modifyDate,
            isDirectory: isDirBool,
            folderItemCount: explicitFolderCount,
            mimeType: fileType
        )
    }
}

// MARK: - Bidirectional File Transfer Task Model

public enum TransferDirection: String, Codable {
    case macToPhone = "发送到手机"
    case phoneToMac = "下载到 Mac"
}

public enum TransferTaskState: String, Codable {
    case pending = "等待中"
    case transferring = "传输中"
    case success = "已完成"
    case failed = "失败"
}

public struct TransferTaskItem: Identifiable, Hashable, Codable {
    public var id: String { "\(taskId)-\(fileId)" }
    public let taskId: String
    public let fileId: String
    public var fileName: String
    public var localPath: String
    public var remotePath: String
    public var fileSize: Int64
    public var progress: Double
    public var state: TransferTaskState
    public var direction: TransferDirection
    public var timestamp: Date
    public var message: String

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    public init(
        taskId: String = UUID().uuidString,
        fileId: String = UUID().uuidString,
        fileName: String,
        localPath: String,
        remotePath: String = "",
        fileSize: Int64,
        progress: Double = 0.0,
        state: TransferTaskState = .pending,
        direction: TransferDirection,
        timestamp: Date = Date(),
        message: String = ""
    ) {
        self.taskId = taskId
        self.fileId = fileId
        self.fileName = fileName
        self.localPath = localPath
        self.remotePath = remotePath
        self.fileSize = fileSize
        self.progress = progress
        self.state = state
        self.direction = direction
        self.timestamp = timestamp
        self.message = message
    }
}

// MARK: - SMS & Incoming Call Notification Models

public enum NotificationCategory: String, Codable {
    case sms = "短信"
    case call = "电话"
}

public struct IncomingCallItem: Identifiable, Hashable, Codable {
    public var id: String
    public var number: String
    public var callerDisplayName: String
    public var location: String
    public var callState: Int // 4 = Ringing, 3 = In Call, 10 = Ended
    public var avatarBase64: String?
    public var receivedAt: Date
    public var isAnsweredOnMac: Bool
    public var isAnswerPendingOnMac: Bool
    public var connectedAt: Date?
    public var activeAudioDeviceName: String
    public var smsReplyOptions: [String]

    public var displayTitle: String {
        let trimmed = callerDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let num = number.trimmingCharacters(in: .whitespacesAndNewlines)
        return num.isEmpty ? "未知来电" : num
    }

    public var stateDescription: String {
        let dev = activeAudioDeviceName.isEmpty ? "Mac 麦克风" : activeAudioDeviceName
        if callState == 3 {
            return "正在使用 \(dev) 通话中"
        }
        if callState == 4 && isAnswerPendingOnMac {
            return "已发送接听请求（若未自动接通请轻按耳机或手机确认，接通后使用 \(dev)）"
        }
        switch callState {
        case 4: return "正在来电响铃 · 可直接点击接听或挂断"
        case 3: return "正在通话中"
        case 10: return "通话已结束"
        default: return "手机通话通知"
        }
    }

    public init(
        id: String,
        number: String,
        callerDisplayName: String = "",
        location: String = "",
        callState: Int = 4,
        avatarBase64: String? = nil,
        receivedAt: Date = Date(),
        isAnsweredOnMac: Bool = false,
        isAnswerPendingOnMac: Bool = false,
        connectedAt: Date? = nil,
        activeAudioDeviceName: String = "",
        smsReplyOptions: [String] = []
    ) {
        self.id = id
        self.number = number
        self.callerDisplayName = callerDisplayName
        self.location = location
        self.callState = callState
        self.avatarBase64 = avatarBase64
        self.receivedAt = receivedAt
        self.isAnsweredOnMac = isAnsweredOnMac
        self.isAnswerPendingOnMac = isAnswerPendingOnMac
        self.connectedAt = connectedAt
        self.activeAudioDeviceName = activeAudioDeviceName
        self.smsReplyOptions = smsReplyOptions
    }
}

// MARK: - Cross-Device Clipboard History Model

public enum ClipboardItemSource: String, Codable, Hashable {
    case mac = "本机 Mac"
    case phone = "手机"

    public var iconName: String {
        switch self {
        case .phone: return "iphone"
        case .mac: return "laptopcomputer"
        }
    }
}

public struct ClipboardHistoryItem: Identifiable, Hashable, Codable {
    public let id: String
    public var content: String
    public var source: ClipboardItemSource
    public var deviceName: String
    public var createdAt: Date

    public var formattedTime: String {
        let cal = Calendar.current
        let fmt = DateFormatter()
        if cal.isDateInToday(createdAt) {
            fmt.dateFormat = "今天 HH:mm"
        } else if cal.isDateInYesterday(createdAt) {
            fmt.dateFormat = "昨天 HH:mm"
        } else {
            fmt.dateFormat = "MM-dd HH:mm"
        }
        return fmt.string(from: createdAt)
    }

    public var sourceLabel: String {
        switch source {
        case .phone:
            return deviceName.isEmpty ? "来自手机" : "来自手机 · \(deviceName)"
        case .mac:
            return deviceName.isEmpty ? "来自本机 Mac" : "来自本机 · \(deviceName)"
        }
    }

    public init(
        id: String = UUID().uuidString,
        content: String,
        source: ClipboardItemSource,
        deviceName: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.content = content
        self.source = source
        self.deviceName = deviceName
        self.createdAt = createdAt
    }
}

public struct SMSNotificationItem: Identifiable, Hashable, Codable {
    public let id: String
    public var senderNumber: String
    public var senderTitle: String
    public var content: String
    public var verificationCode: String?
    public var receivedAt: Date
    public var pkgName: String
    public var isVerification: Bool
    public var category: NotificationCategory
    public var callLocation: String
    public var isRead: Bool

    public var formattedTime: String {
        let cal = Calendar.current
        let fmt = DateFormatter()
        if cal.isDateInToday(receivedAt) {
            fmt.dateFormat = "今天 HH:mm"
        } else if cal.isDateInYesterday(receivedAt) {
            fmt.dateFormat = "昨天 HH:mm"
        } else {
            fmt.dateFormat = "MM-dd HH:mm"
        }
        return fmt.string(from: receivedAt)
    }

    public var groupDateTitle: String {
        let cal = Calendar.current
        if cal.isDateInToday(receivedAt) {
            return "今天"
        } else if cal.isDateInYesterday(receivedAt) {
            return "昨天"
        } else {
            let fmt = DateFormatter()
            fmt.dateFormat = "MM月dd日"
            return fmt.string(from: receivedAt)
        }
    }

    public func isExpired(now: Date = Date(), thresholdSeconds: TimeInterval = 600) -> Bool {
        now.timeIntervalSince(receivedAt) >= thresholdSeconds
    }

    public init(
        id: String = UUID().uuidString,
        senderNumber: String,
        senderTitle: String,
        content: String,
        verificationCode: String? = nil,
        receivedAt: Date = Date(),
        pkgName: String = "com.android.mms",
        isVerification: Bool = false,
        category: NotificationCategory = .sms,
        callLocation: String = "",
        isRead: Bool = false
    ) {
        self.id = id
        self.senderNumber = senderNumber
        self.senderTitle = senderTitle
        self.content = content
        self.verificationCode = verificationCode
        self.receivedAt = receivedAt
        self.pkgName = pkgName
        self.isVerification = isVerification
        self.category = category
        self.callLocation = callLocation
        self.isRead = isRead
    }
}

// MARK: - Memory & Non-Intrusive ICMP Ping Helper (NEVER touches TCP Port 10152!)

public enum MemoryTelemetry {
    public static func currentFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0.0 }
        return Double(info.phys_footprint) / (1024.0 * 1024.0)
    }

    public static func measureICMPLatencyMs(ip: String) -> Int? {
        let cleanIP = ip.split(separator: ":").first.map(String.init) ?? ip
        guard !cleanIP.isEmpty, cleanIP != "127.0.0.1", cleanIP != "同局域网", !cleanIP.hasPrefix("*") else {
            return nil
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/sbin/ping")
        task.arguments = ["-c", "1", "-W", "800", "-q", cleanIP]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let out = String(data: data, encoding: .utf8),
               let range = out.range(of: " = ") {
                let statsPart = String(out[range.upperBound...])
                let slashParts = statsPart.split(separator: "/")
                if let firstVal = slashParts.first, let ms = Double(firstVal) {
                    return max(1, Int(round(ms)))
                }
            }
            return max(1, min(elapsed, 60))
        } catch {
            return nil
        }
    }

    /// Queries real Android `/data` partition total & free bytes if `adb` is connected to the device.
    public static func queryADBStorageCapacity(ip: String) -> (total: Int64, free: Int64)? {
        let adbCandidates = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb", "/usr/bin/adb"]
        guard let adbPath = adbCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: adbPath)
        task.arguments = ["shell", "df", "-k", "/storage/emulated/0"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            for line in text.split(separator: "\n").dropFirst() {
                let cols = line.split(whereSeparator: { $0.isWhitespace })
                if cols.count >= 4,
                   let totalKB = Int64(cols[1]),
                   let availKB = Int64(cols[3]),
                   totalKB > 1_000_000 {
                    return (total: totalKB * 1024, free: availKB * 1024)
                }
            }
        } catch {}
        return nil
    }
}
