import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Menu Bar Popover for ColorDrop
public struct MenuBarConnectView: View {
    @ObservedObject var coordinator: ConnectCoordinator
    @Environment(\.openWindow) private var openWindow

    public init(coordinator: ConnectCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 1. Top Device Status Row
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 38, height: 38)
                    Image(systemName: "iphone")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.blue)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(coordinator.connectedDevice?.deviceName ?? "未连接手机")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(deviceSubheadlineText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(coordinator.connectedDevice != nil ? "在线" : "离线")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(coordinator.connectedDevice != nil ? Color(red: 0.11, green: 0.54, blue: 0.34) : .secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(
                        coordinator.connectedDevice != nil
                            ? Color(red: 0.85, green: 0.96, blue: 0.90)
                            : Color.secondary.opacity(0.12)
                    )
                    .clipShape(Capsule())
            }
            .padding(16)

            Divider().opacity(0.45)

            // 2. Two-Column Quick Action Buttons (`发送文件` -> Download/ColorDrop, `接收文件夹`)
            HStack(spacing: 10) {
                Button {
                    coordinator.pickAndSendFilesFromMenuBar()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "paperplane")
                            .font(.system(size: 13, weight: .medium))
                        Text("发送文件")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.primary.opacity(0.14), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
                .help("发送文件到手机 Download/ColorDrop 文件夹")

                Button {
                    coordinator.openReceiveDirectoryInFinder()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 13, weight: .medium))
                        Text("接收文件夹")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.primary.opacity(0.14), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(14)

            // 3. Incoming Call Section (if ringing or in call on Mac) OR Latest Verification Code Section
            if let call = coordinator.activeIncomingCall {
                Divider().opacity(0.45)

                let isCallConnected = (call.callState == 3)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(isCallConnected ? "正在通话中" : "手机来电")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(isCallConnected ? CallAudioRelayService.shared.formattedCallDuration : call.location)
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(isCallConnected ? Color(red: 0.11, green: 0.54, blue: 0.34) : .secondary)
                    }

                    HStack(spacing: 8) {
                        Text(call.displayTitle)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.blue)
                            .lineLimit(1)

                        Spacer()

                        if isCallConnected {
                            Button {
                                coordinator.toggleCallMicrophoneMute()
                            } label: {
                                Text(CallAudioRelayService.shared.isMicrophoneMuted ? "取消静音" : "静音")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(Color.primary.opacity(0.16), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button {
                                coordinator.answerCurrentCallOnMac()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: CallAudioRelayService.shared.isUsingHeadphones ? "headphones" : "phone.fill")
                                        .font(.system(size: 11, weight: .bold))
                                    Text("接听")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color(red: 0.16, green: 0.78, blue: 0.37))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }

                        Button {
                            coordinator.hangupCurrentCall()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "phone.down.fill")
                                    .font(.system(size: 11, weight: .bold))
                                Text("挂断")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color(red: 0.95, green: 0.23, blue: 0.21))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    Text(
                        isCallConnected
                            ? "麦克风：\(CallAudioRelayService.shared.activeInputDeviceName)"
                            : (call.isAnswerPendingOnMac
                               ? "已请求接听 · 轻按耳机或手机确认（使用 \(CallAudioRelayService.shared.activeInputDeviceName)）"
                               : "点击接听将使用 \(CallAudioRelayService.shared.activeInputDeviceName) 通话")
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(call.isAnswerPendingOnMac ? .blue : .secondary)
                    .lineLimit(1)
                }
                .padding(16)
            } else if let verifSMS = coordinator.latestVerificationSMS,
                      let code = verifSMS.verificationCode {
                let isJustCopied = coordinator.copiedMessageId == verifSMS.id
                Divider().opacity(0.45)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("最新验证码")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(verifSMS.senderTitle) · \(verifSMS.formattedTime)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text(code)
                            .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.blue)

                        Spacer()

                        Button {
                            coordinator.copyVerificationCode(code, messageId: verifSMS.id)
                        } label: {
                            Text(isJustCopied ? "已复制 ✓" : "复制")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(
                                    isJustCopied
                                        ? Color(red: 0.16, green: 0.65, blue: 0.38)
                                        : Color(red: 0.08, green: 0.09, blue: 0.12)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }

                    Text("已自动复制到剪贴板")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }

            Divider().opacity(0.45)

            // 4. Bottom Footer (`默认发送至 Download/ColorDrop` + `主界面`)
            HStack(spacing: 8) {
                Text("默认发送至 Download/ColorDrop")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                Button {
                    focusOrOpenSingleMainWindow()
                } label: {
                    Text("主界面")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 296)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        .onAppear {
            StatusBarDropController.shared.hideDropPanelImmediately()
        }
        .onDrop(of: [.fileURL], isTargeted: $coordinator.isMenuBarDropTargeted) { providers in
            handleMenuBarDrop(providers)
        }
        .overlay {
            if coordinator.isMenuBarDropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(Color.blue.opacity(0.08))
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: "arrow.up.doc.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(.blue)
                            Text("松开立即发送至手机 Download/ColorDrop")
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .padding(6)
            }
        }
    }

    private func handleMenuBarDrop(_ providers: [NSItemProvider]) -> Bool {
        var collected: [URL] = []
        let group = DispatchGroup()
        let lock = NSLock()

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    lock.lock()
                    collected.append(url)
                    lock.unlock()
                } else if let url = item as? URL {
                    lock.lock()
                    collected.append(url)
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            if !collected.isEmpty {
                coordinator.sendLocalFilesToPhone(
                    urls: collected,
                    explicitTargetDirectory: ConnectCoordinator.menuBarDefaultRemoteDirectory
                )
            }
        }
        return true
    }

    /// Reuses an existing main window if present; only calls `openWindow(id: "main")` when no main window exists.
    private func focusOrOpenSingleMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let primary = ColorDropAppDelegate.shared.mainWindow ?? ColorDropAppDelegate.shared.findExistingMainWindow() {
            ColorDropAppDelegate.shared.mainWindow = primary
            if primary.isMiniaturized {
                primary.deminiaturize(nil)
            }
            primary.makeKeyAndOrderFront(nil)
            primary.orderFrontRegardless()
        } else {
            openWindow(id: "main")
        }
    }

    private var deviceSubheadlineText: String {
        guard let dev = coordinator.connectedDevice else {
            return "同一 Wi-Fi 自动发现"
        }
        if let bat = dev.batteryLevel {
            return "已连接 · 电量 \(bat)%"
        }
        return "已连接 · Wi-Fi"
    }
}
