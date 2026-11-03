import SwiftUI
import AppKit
import Foundation
import CoreGraphics
import ImageIO

@main
public struct OppoLiteConnectApp {
    public static func main() {
        if CommandLine.arguments.contains("--self-test") {
            runSelfTest()
            return
        }
        if CommandLine.arguments.contains("--sync-icon-only") {
            ColorDropGUIApp.applyCustomIconIfAvailable()
            return
        }
        ColorDropGUIApp.main()
    }

    private static func runSelfTest() {
        print("=== ColorDrop v1.0.0 原生自检 ===")
        let discovery = LanSdpDiscovery()
        print("1. 本地设备 ID: \(discovery.localDeviceId) | 局域网 IP: \(discovery.localIPv4) | 本机IP过滤校验: \(discovery.isSelfAddress(discovery.localIPv4))")
        assert(discovery.isSelfAddress(discovery.localIPv4), "Must filter out Mac's own IP address")

        let unmasked = DspIPCClient.unmaskDaemonIP("*.*.31.162:10152", localIP: "192.168.31.231")
        assert(unmasked == "192.168.31.162:10152", "Must unmask daemon IP")
        print("2. 守护进程 IP 解码校验通过: *.*.31.162:10152 -> \(unmasked)")

        let smsService = SMSNotificationService.shared
        smsService.autoCopyVerificationCode = false

        let wechatBlocked = smsService.processIncomingNotification(
            topicKey: "SYNERGY_NOTIFICATION_ADD",
            payload: [
                "key": "test-wx",
                "pkgName": "com.tencent.mm",
                "headerView": ["label": "微信"],
                "contractedChild": ["contractedTitle": "张三", "contractedContent": "在吗"]
            ]
        )
        assert(wechatBlocked == nil, "WeChat notification must be blocked by SMS/Call filter")

        let smsAccepted = smsService.processIncomingNotification(
            topicKey: "SYNERGY_NOTIFICATION_ADD",
            payload: [
                "key": "test-sms",
                "pkgName": "com.oplus.mms",
                "headerView": ["label": "信息"],
                "contractedChild": [
                    "contractedTitle": "新浪",
                    "contractedContent": "【新浪网】您的验证码是：156807，请在10分钟内输入。"
                ]
            ]
        )
        assert(smsAccepted?.verificationCode == "156807" && smsAccepted?.senderTitle == "新浪", "SMS verification code must be extracted")

        let callAccepted = smsService.processIncomingCallInfo(payload: [
            "id": "DialerCall_12",
            "number": "17681396427",
            "callerDisplayName": "",
            "location": "安徽铜陵 联通",
            "callState": 4,
            "isIncallui": true
        ])
        assert(callAccepted?.callState == 4 && callAccepted?.displayTitle == "17681396427", "Incoming call must be parsed")
        print("3. 精简通知模板校验通过 (单图标): 短信标题=\(smsAccepted?.senderTitle ?? "") 正文=\(smsAccepted?.content ?? "") | 来电标题=\(callAccepted?.displayTitle ?? "") 正文=来电 · \(callAccepted?.location ?? "")")

        let sampleDev = OppoDevice(
            deviceId: "2B04DFC2AC20",
            deviceName: "OnePlus 15",
            lanIP: "192.168.31.215",
            phoneModel: "PLK110",
            osVersionName: "ColorOS 16",
            screenResolution: "1272*2772",
            indexedMediaBytes: 64_900_000_000,
            indexedMediaCount: 3842,
            categoryBreakdownText: "图片 16.2 GB · 视频 48.0 GB · 文档与其它 700 MB"
        )
        assert(sampleDev.formattedSystemValue == "ColorOS 16 · PLK110", "System version and model must match real phone switchStatus")
        print("4. 真实系统型号与共享文件统计校验通过: \(sampleDev.formattedSystemValue) (\(sampleDev.formattedSystemSubtitle)) | \(sampleDev.formattedStorageValue)")

        let oshare = OShareEngine.shared
        let sslBundlePath = oshare.ensureSSLBundlePath()
        let deletePayload = DspIPCClient.shared.buildDeleteFilesPayload(filePaths: ["/storage/emulated/0/Download/test.txt"])
        let mkdirPayload = DspIPCClient.shared.buildCreateFolderPayload(parentPath: "/storage/emulated/0/Download", folderName: "ColorDrop")
        assert((deletePayload["api"] as? String) == "file.operate", "Delete payload must use file.operate")
        assert((mkdirPayload["api"] as? String) == "file.operate", "Create folder payload must use file.operate")
        assert(ConnectCoordinator.menuBarDefaultRemoteDirectory == "/storage/emulated/0/Download/ColorDrop", "Menu bar default directory must be Download/ColorDrop")

        let parsedItem = RemoteFileItem.fromAgentDict([
            "fileName": "Alarms",
            "filePath": "/storage/emulated/0/Alarms",
            "isDirectory": true,
            "folderItem": 0,
            "dataModified": "2026-09-18 10:25:00"
        ])
        assert(parsedItem?.formattedDate == "2026-09-18 10:25", "Modification date string must be parsed accurately")
        print("5. 状态栏快传目录 (\(ConnectCoordinator.menuBarDefaultRemoteDirectory))、主界面目录直传与真实文件修改时间解析 (\(parsedItem?.formattedDate ?? "")) 校验通过: FFI加载=\(oshare.isFFILoaded) | 服务端口=\(String(oshare.localServerPort)) | SSL资源包=\(sslBundlePath)")

        let memMB = MemoryTelemetry.currentFootprintMB()
        print(String(format: "6. 当前进程物理内存占用 (phys_footprint): %.2f MB", memMB))
        print("=== 全部自检通过 (v1.0.0) ===")
    }
}

public struct ColorDropGUIApp: App {
    @StateObject private var coordinator = ConnectCoordinator.shared

    public init() {
        NSApplication.shared.setActivationPolicy(.regular)
        Self.applyCustomIconIfAvailable()
    }

    /// Loads `/Users/micage/Downloads/iconbase-icons (1)/android-chrome-192x192.png` first,
    /// normalizes it to Apple's macOS HIG squircle grid (`824/1024`), sets the Dock icon,
    /// and updates `Vendor/iconbase_192.png` + `AppIcon.icns`.
    public static func applyCustomIconIfAvailable() {
        let cwd = FileManager.default.currentDirectoryPath
        let primaryIconPath = "/Users/micage/Downloads/iconbase-icons (1)/android-chrome-192x192.png"
        let vendorCopyPath = "/Users/micage/Documents/Gemini/OppoLiteConnect/Vendor/iconbase_192.png"
        let cwdVendorPath = "\(cwd)/Vendor/iconbase_192.png"

        if FileManager.default.fileExists(atPath: primaryIconPath),
           let rawData = try? Data(contentsOf: URL(fileURLWithPath: primaryIconPath)) {
            try? rawData.write(to: URL(fileURLWithPath: vendorCopyPath), options: .atomic)
        }

        let execURL = URL(fileURLWithPath: CommandLine.arguments.first ?? Bundle.main.executablePath ?? "")
        let inferredBundleResDir = execURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
            .path

        let candidatePaths: [String] = [
            primaryIconPath,
            vendorCopyPath,
            cwdVendorPath,
            "/Users/micage/Downloads/iconbase-icons/desktop-1024x1024.png",
            "/Users/micage/Documents/Gemini/OppoLiteConnect/Vendor/iconbase_raw_1024.png",
            "\(cwd)/Vendor/iconbase_raw_1024.png",
            "\(inferredBundleResDir)/AppIcon.png",
            Bundle.main.bundlePath + "/Contents/Resources/AppIcon.png"
        ]

        for path in candidatePaths where FileManager.default.fileExists(atPath: path) {
            if let normalizedPng = Self.renderMacOSHIGIconPNG(fromPath: path, canvasSize: 1024) {
                if !CommandLine.arguments.contains("--sync-icon-only"),
                   let nsImage = NSImage(data: normalizedPng) {
                    nsImage.size = NSSize(width: 512, height: 512)
                    NSApplication.shared.applicationIconImage = nsImage
                }

                if FileManager.default.fileExists(atPath: "/Users/micage/Documents/Gemini") {
                    let cacheIconPath = "/Users/micage/Documents/Gemini/oppodat/app_notification_icon.png"
                    try? FileManager.default.createDirectory(
                        atPath: "/Users/micage/Documents/Gemini/oppodat",
                        withIntermediateDirectories: true
                    )
                    try? normalizedPng.write(to: URL(fileURLWithPath: cacheIconPath), options: .atomic)
                }

                // Update `AppIcon.png` & multi-resolution `AppIcon.icns` in both inferred bundle & local ColorDrop.app
                let targetResDirs = Set([
                    inferredBundleResDir,
                    Bundle.main.bundlePath + "/Contents/Resources",
                    "/Users/micage/Documents/Gemini/ColorDrop.app/Contents/Resources"
                ])
                for resDir in targetResDirs where FileManager.default.fileExists(atPath: resDir) {
                    try? normalizedPng.write(to: URL(fileURLWithPath: "\(resDir)/AppIcon.png"), options: .atomic)
                    Self.writeMultiSizeIcns(fromSourcePath: path, toPath: "\(resDir)/AppIcon.icns")
                }
                break
            }
        }
    }

    public static func renderMacOSHIGIconPNG(fromPath path: String, canvasSize: Int = 1024) -> Data? {
        guard let srcImage = NSImage(contentsOfFile: path),
              let cgImage = srcImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let srcW = cgImage.width
        let srcH = cgImage.height

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: canvasSize,
            height: canvasSize,
            bitsPerComponent: 8,
            bytesPerRow: canvasSize * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        ctx.interpolationQuality = .high

        // Trim any tiny outer bleed (~1.5%) so the artwork fills the standard 824/1024 macOS HIG squircle cleanly
        let cropInsetRatio: CGFloat = 16.0 / 1024.0
        let cropRect = CGRect(
            x: CGFloat(srcW) * cropInsetRatio,
            y: CGFloat(srcH) * cropInsetRatio,
            width: CGFloat(srcW) * (1.0 - 2.0 * cropInsetRatio),
            height: CGFloat(srcH) * (1.0 - 2.0 * cropInsetRatio)
        )
        let croppedCG = cgImage.cropping(to: cropRect) ?? cgImage

        let bodySide = CGFloat(canvasSize) * (824.0 / 1024.0)
        let margin = (CGFloat(canvasSize) - bodySide) / 2.0
        let cornerRadius = bodySide * (185.4 / 824.0)
        let targetRect = CGRect(x: margin, y: margin, width: bodySide, height: bodySide)

        ctx.saveGState()
        let clipPath = CGPath(roundedRect: targetRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        ctx.addPath(clipPath)
        ctx.clip()
        ctx.draw(croppedCG, in: targetRect)
        ctx.restoreGState()

        guard let outCG = ctx.makeImage() else { return nil }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData as CFMutableData, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, outCG, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }

    public static func writeMultiSizeIcns(fromSourcePath path: String, toPath icnsPath: String) {
        let specs: [(tag: String, size: Int)] = [
            ("icp4", 16),
            ("icp5", 32),
            ("icp6", 64),
            ("ic07", 128),
            ("ic08", 256),
            ("ic09", 512),
            ("ic10", 1024),
            ("ic11", 32),
            ("ic12", 64),
            ("ic13", 256),
            ("ic14", 512)
        ]
        var allChunks = Data()
        for spec in specs {
            if let pngData = renderMacOSHIGIconPNG(fromPath: path, canvasSize: spec.size) {
                let len = UInt32(8 + pngData.count).bigEndian
                allChunks.append(contentsOf: spec.tag.utf8)
                withUnsafeBytes(of: len) { allChunks.append(contentsOf: $0) }
                allChunks.append(pngData)
            }
        }
        guard !allChunks.isEmpty else { return }
        var icns = Data()
        let totalLen = UInt32(8 + allChunks.count).bigEndian
        icns.append(contentsOf: "icns".utf8)
        withUnsafeBytes(of: totalLen) { icns.append(contentsOf: $0) }
        icns.append(allChunks)
        try? icns.write(to: URL(fileURLWithPath: icnsPath), options: .atomic)
    }

    public var body: some Scene {
        Window("ColorDrop", id: "main") {
            MainConnectView(coordinator: coordinator)
        }
        .defaultSize(width: 900, height: 580)
        .windowStyle(.titleBar)

        MenuBarExtra {
            MenuBarConnectView(coordinator: coordinator)
        } label: {
            Image(systemName: coordinator.connectedDevice != nil ? "iphone.radiowaves.left.and.right" : "iphone")
        }
        .menuBarExtraStyle(.window)
    }
}
