import Foundation
import AppKit
import UserNotifications

/// SMS & Phone Call Notification Synchronization Service
///
/// Listens to `Oplus_HeySynergy_PcConnect_SyncNotification_Publisher` and `Oplus_MacConnect`:
/// - Extracts the real phone notification timestamp (`headerView.whenTime` / `whenTime` / `postTime`) so the timeline
///   in ColorDrop matches the phone 100%.
/// - Persists delivered notification signatures on disk (`/tmp/oppolite-oppodat/delivered_notifications.json`) so unread
///   notifications on the phone are pushed to macOS Notification Center strictly ONCE and never re-popped on reconnect.
/// - Delivers native macOS incoming call notifications via `UNUserNotificationCenter` with only a "挂断" (Hangup) action.
public final class SMSNotificationService: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public static let shared = SMSNotificationService()

    public static let incomingCallCategoryIdentifier = "COLORDROP_INCOMING_CALL"
    public static let hangupCallActionIdentifier = "ACTION_HANGUP_CALL"

    public static let allowedSMSPackages: Set<String> = [
        "com.android.mms",
        "com.oplus.mms",
        "com.coloros.mms",
        "com.oneplus.mms",
        "com.heytap.mms",
        "com.google.android.apps.messaging",
        "com.android.mms.service"
    ]

    public static let allowedCallPackages: Set<String> = [
        "com.android.incallui",
        "com.oplus.incallui",
        "com.coloros.incallui",
        "com.oneplus.incallui",
        "com.android.contacts",
        "com.oplus.contacts",
        "com.android.dialer",
        "com.oneplus.dialer",
        "com.google.android.dialer",
        "com.android.server.telecom"
    ]

    public static let allowedSMSLabels: Set<String> = [
        "短信", "信息", "Messages", "SMS", "MMS", "验证码"
    ]

    public static let allowedCallLabels: Set<String> = [
        "电话", "通话", "未接来电", "Phone", "Call"
    ]

    public var autoCopyVerificationCode: Bool = true

    private let lock = NSLock()
    private var _blockedNonSMSCount: Int = 0
    private var recentSMSItems: [SMSNotificationItem] = []
    private var lastDeliveredCallStates: [String: Int] = [:]
    private var callStartDates: [String: Date] = [:]
    private var deliveredNotificationSignatures: [String] = []
    private var deliveredSignatureSet: Set<String> = []
    private let deliveredSignaturesFilePath = "/tmp/oppolite-oppodat/delivered_notifications.json"
    private let maxStoredSignatures = 600

    public var blockedNonSMSCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _blockedNonSMSCount
    }

    public var onSMSReceived: ((SMSNotificationItem) -> Void)?
    public var onActiveCallChanged: ((IncomingCallItem?) -> Void)?
    public var onBlockedCountChanged: ((Int) -> Void)?
    public var onHangupCallRequested: ((String, String) -> Void)?

    public override init() {
        super.init()
        loadDeliveredSignaturesFromDisk()
        configureInteractiveNotificationCategories()
    }

    /// Seeds existing message history from `ConnectCoordinator` on launch so historical items are never re-popped.
    public func seedExistingHistory(_ items: [SMSNotificationItem]) {
        lock.lock()
        for item in items {
            if !recentSMSItems.contains(where: { $0.id == item.id }) {
                recentSMSItems.append(item)
            }
            for sig in Self.computeSignatures(
                id: item.id,
                category: item.category,
                senderTitle: item.senderTitle,
                content: item.content,
                date: item.receivedAt
            ) {
                recordSignatureLocked(sig)
            }
        }
        saveDeliveredSignaturesLocked()
        lock.unlock()
    }

    private func loadDeliveredSignaturesFromDisk() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: deliveredSignaturesFilePath)),
              let arr = try? JSONDecoder().decode([String].self, from: data) else {
            return
        }
        lock.lock()
        deliveredNotificationSignatures = arr
        deliveredSignatureSet = Set(arr)
        lock.unlock()
    }

    private func recordSignatureLocked(_ sig: String) {
        guard !sig.isEmpty, !deliveredSignatureSet.contains(sig) else { return }
        deliveredSignatureSet.insert(sig)
        deliveredNotificationSignatures.append(sig)
        if deliveredNotificationSignatures.count > maxStoredSignatures {
            let removed = deliveredNotificationSignatures.removeFirst()
            deliveredSignatureSet.remove(removed)
        }
    }

    private func saveDeliveredSignaturesLocked() {
        let snapshot = deliveredNotificationSignatures
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: URL(fileURLWithPath: deliveredSignaturesFilePath), options: .atomic)
        }
    }

    private static func computeSignatures(
        id: String,
        category: NotificationCategory,
        senderTitle: String,
        content: String,
        date: Date
    ) -> [String] {
        let secBucket = Int64(date.timeIntervalSince1970)
        let minBucket = Int64(date.timeIntervalSince1970 / 60)
        var sigs: [String] = [
            "id_ts:\(id)|\(secBucket)",
            "content_min:\(category.rawValue)|\(senderTitle)|\(content)|\(minBucket)",
            "id_content:\(id)|\(content)"
        ]
        if !id.isEmpty && id.contains("|") {
            sigs.append("android_key:\(id)|\(secBucket)")
        }
        return sigs
    }

    /// Extracts the real notification timestamp from the phone's payload (`headerView.whenTime`, `whenTime`, `postTime`, etc.)
    /// so the timeline in ColorDrop matches the phone 100% rather than showing Mac's reconnect time.
    public static func extractPhoneTimestamp(from payload: [String: Any], fallbackContent: String = "") -> Date? {
        func parseRawTimestamp(_ anyVal: Any?) -> Date? {
            guard let raw = anyVal else { return nil }
            let valDouble: Double?
            if let i64 = raw as? Int64 {
                valDouble = Double(i64)
            } else if let i = raw as? Int {
                valDouble = Double(i)
            } else if let d = raw as? Double {
                valDouble = d
            } else if let s = raw as? String, let parsed = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                valDouble = parsed
            } else {
                valDouble = nil
            }
            guard let ts = valDouble, ts > 100_000_000 else { return nil }
            let seconds = ts > 2_000_000_000 ? (ts / 1000.0) : ts
            return Date(timeIntervalSince1970: seconds)
        }

        if let headerView = payload["headerView"] as? [String: Any] {
            for key in ["whenTime", "when", "postTime", "time", "timestamp"] {
                if let date = parseRawTimestamp(headerView[key]) {
                    return date
                }
            }
        }
        for key in ["whenTime", "postTime", "when", "timestamp", "time", "createTime", "date"] {
            if let date = parseRawTimestamp(payload[key]) {
                return date
            }
        }

        // Fallback: if SMS body contains an explicit date/time like `11月04日 16:03`, parse it in current year
        if !fallbackContent.isEmpty {
            let pattern = "([0-9]{1,2})月([0-9]{1,2})日\\s*([0-9]{1,2}):([0-9]{2})"
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: fallbackContent, range: NSRange(fallbackContent.startIndex..<fallbackContent.endIndex, in: fallbackContent)),
               match.numberOfRanges == 5,
               let rMonth = Range(match.range(at: 1), in: fallbackContent),
               let rDay = Range(match.range(at: 2), in: fallbackContent),
               let rHour = Range(match.range(at: 3), in: fallbackContent),
               let rMin = Range(match.range(at: 4), in: fallbackContent),
               let month = Int(fallbackContent[rMonth]),
               let day = Int(fallbackContent[rDay]),
               let hour = Int(fallbackContent[rHour]),
               let minute = Int(fallbackContent[rMin]) {
                var cal = Calendar.current
                cal.timeZone = .current
                var comps = cal.dateComponents([.year], from: Date())
                comps.month = month
                comps.day = day
                comps.hour = hour
                comps.minute = minute
                comps.second = 0
                if let parsed = cal.date(from: comps) {
                    return parsed
                }
            }
        }
        return nil
    }

    /// Registers the `"COLORDROP_INCOMING_CALL"` category on macOS native `UNUserNotificationCenter`
    /// with ONLY the `"挂断"` (Hangup) action.
    public func configureInteractiveNotificationCategories() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let hangupAction = UNNotificationAction(
            identifier: Self.hangupCallActionIdentifier,
            title: "挂断",
            options: [.destructive]
        )
        let callCategory = UNNotificationCategory(
            identifier: Self.incomingCallCategoryIdentifier,
            actions: [hangupAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        center.setNotificationCategories([callCategory])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let callId = (userInfo["callId"] as? String) ?? "DialerCall"
        let number = (userInfo["number"] as? String) ?? ""
        let actionId = response.actionIdentifier

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if actionId == Self.hangupCallActionIdentifier {
                self.onHangupCallRequested?(callId, number)
            }
        }
        completionHandler()
    }

    // MARK: - Strict SMS & Phone Call Filter

    public func isAllowedNotification(payload: [String: Any], topicKey: String? = nil) -> Bool {
        if topicKey == "VerificationCode" || topicKey == "incallui_info" {
            return true
        }
        if let rawKey = payload["key"] as? String, rawKey.contains("Aggregate_") {
            return false
        }
        if let groupState = payload["groupState"] as? [String: Any],
           let isSummary = groupState["groupSummary"] as? Bool, isSummary {
            return false
        }

        if let isVerif = payload["isVerification"] as? Bool, isVerif {
            return true
        }
        if let verifCode = payload["verification_code"] as? String, !verifCode.isEmpty {
            return true
        }
        if let pkgName = payload["pkgName"] as? String {
            if Self.allowedSMSPackages.contains(pkgName) || Self.allowedCallPackages.contains(pkgName) {
                return true
            }
            let lowerPkg = pkgName.lowercased()
            if lowerPkg.contains("mms") || lowerPkg.contains("sms") || lowerPkg.contains("incallui") || lowerPkg.contains("dialer") || lowerPkg.contains("telecom") {
                return true
            }
            if let headerView = payload["headerView"] as? [String: Any],
               let label = headerView["label"] as? String {
                let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.allowedSMSLabels.contains(trimmed) || Self.allowedCallLabels.contains(trimmed) {
                    return true
                }
            }
            return false
        }
        if let headerView = payload["headerView"] as? [String: Any],
           let label = headerView["label"] as? String {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.allowedSMSLabels.contains(trimmed) || Self.allowedCallLabels.contains(trimmed) {
                return true
            }
        }
        return false
    }

    public func isAllowedSMSNotification(payload: [String: Any], topicKey: String? = nil) -> Bool {
        isAllowedNotification(payload: payload, topicKey: topicKey)
    }

    // MARK: - Process Real-Time Incoming Call (`key: "incallui_info"` on `Oplus_MacConnect`)

    @discardableResult
    public func processIncomingCallInfo(payload: [String: Any]) -> IncomingCallItem? {
        let callId = (payload["id"] as? String) ?? "DialerCall"
        let number = (payload["number"] as? String) ?? ""
        let callerDisplayName = (payload["callerDisplayName"] as? String) ?? ""
        let location = (payload["location"] as? String) ?? ""
        let avatarB64 = payload["photo"] as? String

        var smsReplies: [String] = []
        if let replyStr = payload["sms_reply_list"] as? String,
           let replyData = replyStr.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: replyData) as? [String] {
            smsReplies = parsed.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        } else if let replyArr = payload["sms_reply_list"] as? [String] {
            smsReplies = replyArr.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }

        let callState: Int
        if let sInt = payload["callState"] as? Int {
            callState = sInt
        } else if let sStr = payload["callState"] as? String, let parsed = Int(sStr) {
            callState = parsed
        } else {
            callState = 4
        }

        let now = Date()
        lock.lock()
        let prevState = lastDeliveredCallStates[callId]
        lastDeliveredCallStates[callId] = callState
        if callState == 4 && callStartDates[callId] == nil {
            callStartDates[callId] = Self.extractPhoneTimestamp(from: payload) ?? now
        }
        let callTimestamp = callStartDates[callId] ?? Self.extractPhoneTimestamp(from: payload) ?? now
        if callState == 10 {
            callStartDates.removeValue(forKey: callId)
        }
        lock.unlock()

        let callItem = IncomingCallItem(
            id: callId,
            number: number,
            callerDisplayName: callerDisplayName,
            location: location,
            callState: callState,
            avatarBase64: avatarB64,
            receivedAt: callTimestamp,
            smsReplyOptions: smsReplies
        )

        let callerLabel = callItem.displayTitle
        let callBody = location.isEmpty ? "来电" : "来电 · \(location)"

        if callState == 4 {
            onActiveCallChanged?(callItem)
            if prevState != 4 {
                deliverCallMacOSBanner(for: callItem)
                DiagnosticLogService.shared.log("收到手机来电响铃: \(callerLabel) (\(callBody))", category: "Call")
            }
            let record = SMSNotificationItem(
                id: "call-\(callId)",
                senderNumber: number.isEmpty ? callerLabel : number,
                senderTitle: callerLabel,
                content: callBody,
                verificationCode: nil,
                receivedAt: callTimestamp,
                pkgName: "com.android.incallui",
                isVerification: false,
                category: .call,
                callLocation: location
            )
            upsertCallRecordInHistory(record)
        } else if callState == 3 {
            onActiveCallChanged?(callItem)
            let record = SMSNotificationItem(
                id: "call-\(callId)",
                senderNumber: number.isEmpty ? callerLabel : number,
                senderTitle: callerLabel,
                content: location.isEmpty ? "通话中" : "通话中 · \(location)",
                verificationCode: nil,
                receivedAt: callTimestamp,
                pkgName: "com.android.incallui",
                isVerification: false,
                category: .call,
                callLocation: location
            )
            upsertCallRecordInHistory(record)
        } else if callState == 10 {
            onActiveCallChanged?(nil)
            removeDeliveredCallBanner(callId: callId)
            let record = SMSNotificationItem(
                id: "call-\(callId)",
                senderNumber: number.isEmpty ? callerLabel : number,
                senderTitle: callerLabel,
                content: callBody,
                verificationCode: nil,
                receivedAt: callTimestamp,
                pkgName: "com.android.incallui",
                isVerification: false,
                category: .call,
                callLocation: location
            )
            upsertCallRecordInHistory(record)
        }

        return callItem
    }

    private func upsertCallRecordInHistory(_ item: SMSNotificationItem) {
        var finalItem = item
        lock.lock()
        if let idx = recentSMSItems.firstIndex(where: { $0.id == item.id }) {
            // Preserve the original call arrival time so ending a call doesn't shift its timeline!
            finalItem.receivedAt = recentSMSItems[idx].receivedAt
            finalItem.isRead = recentSMSItems[idx].isRead
            recentSMSItems[idx] = finalItem
        } else {
            recentSMSItems.append(finalItem)
        }
        for sig in Self.computeSignatures(
            id: finalItem.id,
            category: finalItem.category,
            senderTitle: finalItem.senderTitle,
            content: finalItem.content,
            date: finalItem.receivedAt
        ) {
            recordSignatureLocked(sig)
        }
        saveDeliveredSignaturesLocked()
        lock.unlock()
        onSMSReceived?(finalItem)
    }

    // MARK: - Handle Incoming DataBus Notification Event (With True Phone Timestamp & Persistent Deduplication)

    @discardableResult
    public func processIncomingNotification(topicKey: String, payload: [String: Any]) -> SMSNotificationItem? {
        if topicKey == "incallui_info" || (payload["isIncallui"] as? Bool) == true || payload["callState"] != nil {
            _ = processIncomingCallInfo(payload: payload)
            return nil
        }

        guard isAllowedNotification(payload: payload, topicKey: topicKey) else {
            lock.lock()
            _blockedNonSMSCount += 1
            let currentBlocked = _blockedNonSMSCount
            lock.unlock()
            onBlockedCountChanged?(currentBlocked)
            return nil
        }

        let pkgName = (payload["pkgName"] as? String) ?? "com.android.mms"
        let headerView = payload["headerView"] as? [String: Any]
        let contractedChild = payload["contractedChild"] as? [String: Any]
        let headerLabel = (headerView?["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let isCallNotification = Self.allowedCallPackages.contains(pkgName)
            || pkgName.lowercased().contains("incallui")
            || pkgName.lowercased().contains("dialer")
            || Self.allowedCallLabels.contains(headerLabel)

        let rawSenderTitle = (contractedChild?["contractedTitle"] as? String)
            ?? (payload["message_title"] as? String)
            ?? (payload["title"] as? String)
            ?? (payload["number"] as? String)
            ?? (headerView?["label"] as? String)
            ?? (isCallNotification ? "未知来电" : "手机短信")
        let senderTitle = rawSenderTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (isCallNotification ? "未知来电" : "手机短信")
            : rawSenderTitle

        let senderNumber = (payload["number"] as? String) ?? senderTitle
        let callLocation = (payload["location"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let rawContent = (payload["sms_content"] as? String)
            ?? (contractedChild?["contractedContent"] as? String)
            ?? (payload["body"] as? String)
            ?? (payload["content"] as? String)
            ?? ""

        let content: String
        let finalTitle: String
        if isCallNotification {
            if senderTitle.contains("未接") && !rawContent.isEmpty {
                finalTitle = rawContent
                content = callLocation.isEmpty ? "来电" : "来电 · \(callLocation)"
            } else {
                finalTitle = senderTitle
                content = callLocation.isEmpty ? (rawContent.isEmpty ? "来电" : "来电 · \(rawContent)") : "来电 · \(callLocation)"
            }
        } else {
            finalTitle = senderTitle
            content = rawContent
        }

        guard !content.isEmpty else { return nil }

        let explicitCode = payload["verification_code"] as? String
        let extractedCode = isCallNotification ? nil : (explicitCode?.isEmpty == false ? explicitCode : Self.extractVerificationCode(from: content))
        let isVerif = (extractedCode != nil) || ((payload["isVerification"] as? Bool) == true) || (topicKey == "VerificationCode")
        let rawId = (payload["key"] as? String) ?? UUID().uuidString
        let category: NotificationCategory = isCallNotification ? .call : .sms

        let now = Date()
        let phoneDate = Self.extractPhoneTimestamp(from: payload, fallbackContent: content) ?? now
        let candidateSignatures = Self.computeSignatures(
            id: rawId,
            category: category,
            senderTitle: finalTitle,
            content: content,
            date: phoneDate
        )

        lock.lock()
        // Prune only items older than 24 hours (NEVER 90 seconds!) so reconnect replays are always caught
        recentSMSItems.removeAll { now.timeIntervalSince($0.receivedAt) > 86_400 }

        let alreadyDelivered = candidateSignatures.contains(where: { deliveredSignatureSet.contains($0) })

        if let existingIdx = recentSMSItems.firstIndex(where: { existing in
            if existing.id == rawId && abs(existing.receivedAt.timeIntervalSince(phoneDate)) < 3600 {
                return true
            }
            if let c1 = existing.verificationCode, let c2 = extractedCode, !c1.isEmpty, c1 == c2,
               abs(existing.receivedAt.timeIntervalSince(phoneDate)) < 180 {
                return true
            }
            if existing.content == content && existing.senderTitle == finalTitle && abs(existing.receivedAt.timeIntervalSince(phoneDate)) < 3600 {
                return true
            }
            if existing.content == content && abs(existing.receivedAt.timeIntervalSince(phoneDate)) < 90 {
                return true
            }
            if isCallNotification && existing.category == .call {
                let normExisting = existing.senderNumber.replacingOccurrences(of: " ", with: "")
                let normIncoming = finalTitle.replacingOccurrences(of: " ", with: "")
                if !normIncoming.isEmpty && (normExisting == normIncoming || existing.senderTitle.replacingOccurrences(of: " ", with: "") == normIncoming) && abs(existing.receivedAt.timeIntervalSince(phoneDate)) < 60 {
                    return true
                }
            }
            return false
        }) {
            var merged = recentSMSItems[existingIdx]
            let genericTitles: Set<String> = ["手机短信", "信息", "短信", "Messages", "SMS"]
            if genericTitles.contains(merged.senderTitle) && !genericTitles.contains(finalTitle) {
                merged.senderTitle = finalTitle
                merged.senderNumber = senderNumber
            }
            let existingIsMasked = merged.content.contains("请勿泄露，点击查看详情")
            let newIsMasked = content.contains("请勿泄露，点击查看详情")
            if (existingIsMasked && !newIsMasked) || (!newIsMasked && content.count > merged.content.count) {
                merged.content = content
            }
            if merged.verificationCode == nil, let code = extractedCode {
                merged.verificationCode = code
            }
            // Keep the accurate phone timestamp (never overwrite with reconnect time!)
            if Self.extractPhoneTimestamp(from: payload, fallbackContent: content) != nil {
                merged.receivedAt = phoneDate
            }
            recentSMSItems[existingIdx] = merged
            for sig in candidateSignatures { recordSignatureLocked(sig) }
            saveDeliveredSignaturesLocked()
            lock.unlock()

            DiagnosticLogService.shared.log(
                "已合并/忽略重连重复同步通知: \(merged.senderTitle) (手机时间: \(merged.formattedTime), key: \(rawId))",
                category: "Notification"
            )
            onSMSReceived?(merged)
            return merged
        }

        let item = SMSNotificationItem(
            id: rawId,
            senderNumber: senderNumber,
            senderTitle: finalTitle,
            content: content,
            verificationCode: extractedCode,
            receivedAt: phoneDate,
            pkgName: pkgName,
            isVerification: isVerif,
            category: category,
            callLocation: callLocation
        )
        recentSMSItems.append(item)
        for sig in candidateSignatures { recordSignatureLocked(sig) }
        saveDeliveredSignaturesLocked()
        lock.unlock()

        if alreadyDelivered {
            DiagnosticLogService.shared.log(
                "已拦截历史已推送通知的重复弹窗: \(item.senderTitle) (手机时间: \(item.formattedTime), key: \(rawId))",
                category: "Notification"
            )
            onSMSReceived?(item)
            return item
        }

        if autoCopyVerificationCode, let code = extractedCode, !code.isEmpty {
            // Only auto-copy if the verification SMS arrived within the last 3 minutes
            if abs(now.timeIntervalSince(phoneDate)) <= 180 {
                copyToClipboard(code)
            }
        }

        DiagnosticLogService.shared.log(
            "首次推送手机通知至 macOS 通知中心: \(item.senderTitle) (手机时间: \(item.formattedTime), key: \(rawId))",
            category: "Notification"
        )
        deliverMacOSBanner(for: item)
        onSMSReceived?(item)
        return item
    }

    // MARK: - Extract 4-8 Digit Verification Code

    public static func extractVerificationCode(from text: String) -> String? {
        let keywords = ["验证码", "校验码", "动态码", "确认码", "登录码", "code", "Code", "CODE", "OTP"]
        let hasKeyword = keywords.contains { text.contains($0) }
        guard hasKeyword else { return nil }

        let pattern = "(?<![0-9])([0-9]{4,8})(?![0-9])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        if let match = regex.firstMatch(in: text, range: nsRange),
           let codeRange = Range(match.range(at: 1), in: text) {
            return String(text[codeRange])
        }
        return nil
    }

    public func copyToClipboard(_ text: String) {
        DispatchQueue.main.async {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        }
    }

    public func removeDeliveredCallBanner(callId: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: ["call-\(callId)", "call-\(callId)-4"])
    }

    /// Native macOS Incoming Call Notification Banner (via `UNUserNotificationCenter`) with ONLY the `"挂断"` action.
    private func deliverCallMacOSBanner(for call: IncomingCallItem) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = call.displayTitle
            content.subtitle = ""
            content.body = call.location.isEmpty ? "手机来电" : "手机来电 · \(call.location)"
            content.sound = .default
            content.categoryIdentifier = Self.incomingCallCategoryIdentifier
            content.userInfo = [
                "callId": call.id,
                "number": call.number
            ]

            let req = UNNotificationRequest(identifier: "call-\(call.id)-4", content: content, trigger: nil)
            center.add(req)
        }
    }

    /// Native macOS SMS Notification Banner (via `UNUserNotificationCenter`)
    private func deliverMacOSBanner(for item: SMSNotificationItem) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = item.senderTitle
            content.subtitle = ""
            content.body = item.content
            content.sound = .default
            if item.category == .call {
                content.categoryIdentifier = Self.incomingCallCategoryIdentifier
                content.userInfo = [
                    "callId": item.id,
                    "number": item.senderNumber
                ]
            }

            let req = UNNotificationRequest(identifier: item.id, content: content, trigger: nil)
            center.add(req)
        }
    }
}
