import Foundation
import AppKit

/// Structured runtime logger and one-click diagnostic log exporter for ColorDrop.
/// Writes timestamped events to `/tmp/oppolite-oppodat/colordrop.log` and exports a combined
/// diagnostic report (ColorDrop state + runtime logs + daemon log tail) via `NSSavePanel`.
public final class DiagnosticLogService: @unchecked Sendable {
    public static let shared = DiagnosticLogService()

    public let logFilePath = "/tmp/oppolite-oppodat/colordrop.log"
    private let lock = NSLock()
    private var recentEntries: [String] = []
    private let maxInMemoryEntries = 300
    private let maxLogFileSizeBytes: UInt64 = 2 * 1024 * 1024

    public var onLogCountChanged: ((Int) -> Void)?

    public var entryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recentEntries.count
    }

    private init() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: "/tmp/oppolite-oppodat", withIntermediateDirectories: true)
        loadExistingEntries()
    }

    private func loadExistingEntries() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: logFilePath)),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        let lines = text.split(separator: "\n").map(String.init)
        lock.lock()
        recentEntries = Array(lines.suffix(maxInMemoryEntries))
        lock.unlock()
    }

    public func log(_ message: String, level: String = "INFO", category: String = "App") {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let timestamp = fmt.string(from: Date())
        let line = "[\(timestamp)] [\(level)] [\(category)] \(message)"

        lock.lock()
        recentEntries.append(line)
        if recentEntries.count > maxInMemoryEntries {
            recentEntries.removeFirst(recentEntries.count - maxInMemoryEntries)
        }
        let currentCount = recentEntries.count
        lock.unlock()

        appendLineToFile(line)
        onLogCountChanged?(currentCount)
    }

    private func appendLineToFile(_ line: String) {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: logFilePath)
        if let attrs = try? fm.attributesOfItem(atPath: logFilePath),
           let size = attrs[.size] as? UInt64,
           size > maxLogFileSizeBytes {
            lock.lock()
            let snapshot = recentEntries.joined(separator: "\n") + "\n"
            lock.unlock()
            try? snapshot.write(to: url, atomically: true, encoding: .utf8)
            return
        }

        let data = Data((line + "\n").utf8)
        if !fm.fileExists(atPath: logFilePath) {
            try? data.write(to: url, options: .atomic)
            chmod(logFilePath, 0o666)
        } else if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    public func clearLogs() {
        lock.lock()
        recentEntries.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(atPath: logFilePath)
        log("用户已清空运行日志 (ColorDrop v1.1.2)", category: "System")
    }

    /// Builds a comprehensive diagnostic report combining ColorDrop state, app logs, and recent daemon logs.
    public func buildDiagnosticReport(stateSummary: [String: String]) -> String {
        var sections: [String] = []
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss Z"

        sections.append("====================================================")
        sections.append("ColorDrop v1.1.2 诊断日志报告 (Diagnostic Report)")
        sections.append("导出时间: \(fmt.string(from: Date()))")
        sections.append("macOS 版本: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        sections.append("====================================================")

        sections.append("\n[一、当前运行与连接状态快照]")
        for key in stateSummary.keys.sorted() {
            sections.append("\(key): \(stateSummary[key] ?? "")")
        }

        lock.lock()
        let appLines = recentEntries
        lock.unlock()

        sections.append("\n[二、ColorDrop 核心事件日志 (最近 \(appLines.count) 条)]")
        if appLines.isEmpty {
            sections.append("(暂无记录)")
        } else {
            sections.append(contentsOf: appLines)
        }

        sections.append("\n[三、底层跨屏互联守护进程日志摘要 (O+Connect Service)]")
        sections.append(readRecentDaemonLogSummary())

        return sections.joined(separator: "\n") + "\n"
    }

    private func readRecentDaemonLogSummary() -> String {
        let candidateDirs = ["/tmp/devicespace", "/tmp/oppolite-dsplogs-daemon"]
        let fm = FileManager.default
        var latestLogPath: String?
        var latestModDate: Date = .distantPast

        for dir in candidateDirs {
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where file.hasSuffix(".log") && !file.contains("crash") {
                let fullPath = "\(dir)/\(file)"
                if let attrs = try? fm.attributesOfItem(atPath: fullPath),
                   let modDate = attrs[.modificationDate] as? Date,
                   modDate > latestModDate {
                    latestModDate = modDate
                    latestLogPath = fullPath
                }
            }
        }

        guard let logPath = latestLogPath,
              let handle = FileHandle(forReadingAtPath: logPath) else {
            return "(未找到守护进程日志文件)"
        }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        let readBytes: UInt64 = min(fileSize, 256_000)
        try? handle.seek(toOffset: fileSize - readBytes)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else {
            return "(无法读取守护进程日志: \(logPath))"
        }

        var filteredLines: [String] = []
        var suppressedTopic50Count = 0
        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine)
            if line.contains("topic: 50,topic: 50") || line.contains("sessionMgrRdUnlock") || line.contains("convertClassTypeToEnQueueIndex") {
                suppressedTopic50Count += 1
                continue
            }
            if line.contains("ERROR")
                || line.contains("WARN")
                || line.contains("onAgentFound")
                || line.contains("onAgentLost")
                || line.contains("onConnected")
                || line.contains("onDisconnected")
                || line.contains("discovery_query")
                || line.contains("/discovery")
                || line.contains("request_connection")
                || line.contains("stop_connection")
                || line.contains("No socket is alive")
                || line.contains("02-005-001")
                || line.contains("HeySynergy_Notification_Add")
                || line.contains("incallui_info")
                || line.contains("core daemon app start") {
                filteredLines.append(line.count > 360 ? String(line.prefix(360)) + "..." : line)
            }
        }

        var header = "日志文件: \(logPath) (总大小: \(fileSize) bytes"
        if suppressedTopic50Count > 0 {
            header += ", 已折叠重复队列刷屏日志 \(suppressedTopic50Count) 行"
        }
        header += ")\n"
        return header + filteredLines.suffix(120).joined(separator: "\n")
    }
}
