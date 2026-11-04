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
        print("=== ColorDrop v1.0.3 原生自检 ===")
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
            osVersionName: "ColorOS 17",
            screenResolution: "1272*2772",
            indexedMediaBytes: 64_900_000_000,
            indexedMediaCount: 3842,
            categoryBreakdownText: "图片 16.2 GB · 视频 48.0 GB · 其它 700 MB"
        )
        assert(sampleDev.formattedSystemValue == "ColorOS 17 · PLK110", "System version and model must match real phone switchStatus")
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
        assert(oshare.isFFILoaded, "libOshareLib.dylib must be bundled and loaded")
        assert(DspIPCClient.shared.locateSourceDaemonBinaryPath() != nil, "O+Connect Service daemon binary must be bundled")
        print("5. 状态栏快传目录 (\(ConnectCoordinator.menuBarDefaultRemoteDirectory))、主界面目录直传与真实文件修改时间解析 (\(parsedItem?.formattedDate ?? "")) 校验通过: FFI加载=\(oshare.isFFILoaded) | 守护进程就绪=\(DspIPCClient.shared.locateSourceDaemonBinaryPath() != nil) | 服务端口=\(String(oshare.localServerPort)) | SSL资源包=\(sslBundlePath)")

        let memMB = MemoryTelemetry.currentFootprintMB()
        print(String(format: "6. 当前进程物理内存占用 (phys_footprint): %.2f MB", memMB))
        print("=== 全部自检通过 (v1.0.3) ===")
    }
}

/// Handles Dock icon clicks (`applicationShouldHandleReopen`) and hides the main window cleanly on red `x` click
/// so clicking the Dock icon always reopens the main window immediately.
public final class ColorDropAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    public static let shared = ColorDropAppDelegate()
    public weak var mainWindow: NSWindow?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Hide the main window instead of destroying its SwiftUI scene so Dock icon click can always restore it
        sender.orderOut(nil)
        return false
    }

    public func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let win = mainWindow ?? findExistingMainWindow() {
            mainWindow = win
            if win.isMiniaturized {
                win.deminiaturize(nil)
            }
            win.makeKeyAndOrderFront(nil)
            win.orderFrontRegardless()
        }
    }

    public func findExistingMainWindow() -> NSWindow? {
        NSApplication.shared.windows.first { win in
            let className = String(describing: type(of: win))
            guard !className.contains("StatusBar"),
                  !className.contains("MenuBar"),
                  !className.contains("Popup"),
                  !className.contains("Panel") else {
                return false
            }
            return win.title == "ColorDrop" || win.identifier?.rawValue.contains("main") == true || win.frame.width >= 600
        }
    }
}

public struct ColorDropGUIApp: App {
    @NSApplicationDelegateAdaptor(ColorDropAppDelegate.self) private var appDelegate
    @StateObject private var coordinator = ConnectCoordinator.shared

    public init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
    }

    /// Generates `AppIcon.icns` and `AppIcon.png` ONLY during build (`--sync-icon-only`)
    /// from the raw `Vendor/iconbase_192.png` source so the icon is never shrunk a second time at runtime!
    public static func applyCustomIconIfAvailable() {
        let cwd = FileManager.default.currentDirectoryPath
        let execURL = URL(fileURLWithPath: CommandLine.arguments.first ?? Bundle.main.executablePath ?? "")
        let inferredBundleResDir = execURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
            .path

        // NEVER include `AppIcon.png` here — only use the unpadded raw `iconbase_192.png` source!
        let rawSourcePaths: [String] = [
            "\(cwd)/Vendor/iconbase_192.png",
            "\(inferredBundleResDir)/Vendor/iconbase_192.png",
            Bundle.main.bundlePath + "/Contents/Resources/Vendor/iconbase_192.png"
        ]

        for path in rawSourcePaths where FileManager.default.fileExists(atPath: path) {
            if let normalizedPng = Self.renderMacOSHIGIconPNG(fromPath: path, canvasSize: 1024) {
                let targetResDirs = Set([
                    inferredBundleResDir,
                    Bundle.main.bundlePath + "/Contents/Resources"
                ])
                for resDir in targetResDirs where FileManager.default.isWritableFile(atPath: resDir) {
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
