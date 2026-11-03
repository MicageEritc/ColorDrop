import Foundation
import AppKit
import UserNotifications

/// SMS & Phone Call Notification Synchronization Service
///
/// Listens to `Oplus_HeySynergy_PcConnect_SyncNotification_Publisher` and `Oplus_MacConnect`
/// and delivers native macOS notifications with a single app icon (via bundle `AppIcon.icns`,
/// without duplicate `UNNotificationAttachment` icons).
public final class SMSNotificationService: @unchecked Sendable {
    public static let shared = SMSNotificationService()

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
    public private(set) var blockedNonSMSCount: Int = 0
    public var onSMSReceived: ((SMSNotificationItem) -> Void)?
    public var onActiveCallChanged: ((IncomingCallItem?) -> Void)?
    public var onBlockedCountChanged: ((Int) -> Void)?

    private let lock = NSLock()
    private var recentSMSItems: [SMSNotificationItem] = []
    private var lastDeliveredCallStates: [String: Int] = [:]

    public init() {}

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

        let callState: Int
        if let sInt = payload["callState"] as? Int {
            callState = sInt
        } else if let sStr = payload["callState"] as? String, let parsed = Int(sStr) {
            callState = parsed
        } else {
            callState = 4
        }

        let callItem = IncomingCallItem(
            id: callId,
            number: number,
            callerDisplayName: callerDisplayName,
            location: location,
            callState: callState,
            avatarBase64: avatarB64,
            receivedAt: Date()
        )

        lock.lock()
        let prevState = lastDeliveredCallStates[callId]
        lastDeliveredCallStates[callId] = callState
        lock.unlock()

        let callerLabel = callItem.displayTitle
        let callBody = location.isEmpty ? "来电" : "来电 · \(location)"

        if callState == 4 {
            onActiveCallChanged?(callItem)
            let record = SMSNotificationItem(
                id: "call-\(callId)",
                senderNumber: number.isEmpty ? callerLabel : number,
                senderTitle: callerLabel,
                content: callBody,
                verificationCode: nil,
                receivedAt: Date(),
                pkgName: "com.android.incallui",
                isVerification: false,
                category: .call,
                callLocation: location
            )
            upsertCallRecordInHistory(record)
            if prevState != 4 {
                deliverCallMacOSBanner(for: callItem)
            }
        } else if callState == 3 {
            onActiveCallChanged?(callItem)
            let record = SMSNotificationItem(
                id: "call-\(callId)",
                senderNumber: number.isEmpty ? callerLabel : number,
                senderTitle: callerLabel,
                content: location.isEmpty ? "通话中" : "通话中 · \(location)",
                verificationCode: nil,
                receivedAt: Date(),
                pkgName: "com.android.incallui",
                isVerification: false,
                category: .call,
                callLocation: location
            )
            upsertCallRecordInHistory(record)
        } else if callState == 10 {
            onActiveCallChanged?(nil)
            let record = SMSNotificationItem(
                id: "call-\(callId)",
                senderNumber: number.isEmpty ? callerLabel : number,
                senderTitle: callerLabel,
                content: callBody,
                verificationCode: nil,
                receivedAt: Date(),
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
        lock.lock()
        if let idx = recentSMSItems.firstIndex(where: { $0.id == item.id }) {
            recentSMSItems[idx] = item
        } else {
            recentSMSItems.append(item)
        }
        lock.unlock()
        onSMSReceived?(item)
    }

    // MARK: - Handle Incoming DataBus Notification Event (With Dual-Channel Deduplication)

    @discardableResult
    public func processIncomingNotification(topicKey: String, payload: [String: Any]) -> SMSNotificationItem? {
        if topicKey == "incallui_info" || (payload["isIncallui"] as? Bool) == true || payload["callState"] != nil {
            _ = processIncomingCallInfo(payload: payload)
            return nil
        }

        guard isAllowedNotification(payload: payload, topicKey: topicKey) else {
            blockedNonSMSCount += 1
            onBlockedCountChanged?(blockedNonSMSCount)
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
        lock.lock()
        recentSMSItems.removeAll { now.timeIntervalSince($0.receivedAt) > 90 }

        if let existingIdx = recentSMSItems.firstIndex(where: { existing in
            if existing.id == rawId { return true }
            if let c1 = existing.verificationCode, let c2 = extractedCode, !c1.isEmpty, c1 == c2,
               abs(now.timeIntervalSince(existing.receivedAt)) < 60 {
                return true
            }
            if existing.content == content && abs(now.timeIntervalSince(existing.receivedAt)) < 60 {
                return true
            }
            if isCallNotification && existing.category == .call {
                let normExisting = existing.senderNumber.replacingOccurrences(of: " ", with: "")
                let normIncoming = finalTitle.replacingOccurrences(of: " ", with: "")
                if !normIncoming.isEmpty && (normExisting == normIncoming || existing.senderTitle.replacingOccurrences(of: " ", with: "") == normIncoming) && abs(now.timeIntervalSince(existing.receivedAt)) < 30 {
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
            recentSMSItems[existingIdx] = merged
            lock.unlock()

            onSMSReceived?(merged)
            return merged
        }

        let item = SMSNotificationItem(
            id: rawId,
            senderNumber: senderNumber,
            senderTitle: finalTitle,
            content: content,
            verificationCode: extractedCode,
            receivedAt: now,
            pkgName: pkgName,
            isVerification: isVerif,
            category: category,
            callLocation: callLocation
        )
        recentSMSItems.append(item)
        lock.unlock()

        if autoCopyVerificationCode, let code = extractedCode, !code.isEmpty {
            copyToClipboard(code)
        }

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

    // MARK: - Deliver Native macOS Notifications (Single App Icon Only — No Duplicate Attachment Icon)

    /// Incoming Call Notification Template:
    /// 标题：{号码或联系人}
    /// 正文：来电 · {归属地}
    private func deliverCallMacOSBanner(for call: IncomingCallItem) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = call.displayTitle
            content.subtitle = ""
            let loc = call.location.trimmingCharacters(in: .whitespacesAndNewlines)
            content.body = loc.isEmpty ? "来电" : "来电 · \(loc)"
            content.sound = .default

            let req = UNNotificationRequest(identifier: "call-\(call.id)-\(call.callState)", content: content, trigger: nil)
            center.add(req)
        }
    }

    /// SMS Notification Template:
    /// 标题：{发件人}
    /// 正文：{短信内容}
    private func deliverMacOSBanner(for item: SMSNotificationItem) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = item.senderTitle
            content.subtitle = ""
            if item.category == .call {
                let loc = item.callLocation.trimmingCharacters(in: .whitespacesAndNewlines)
                content.body = loc.isEmpty ? (item.content.hasPrefix("来电") ? item.content : "来电") : "来电 · \(loc)"
            } else {
                content.body = item.content
            }
            content.sound = .default

            let req = UNNotificationRequest(identifier: item.id, content: content, trigger: nil)
            center.add(req)
        }
    }
}
