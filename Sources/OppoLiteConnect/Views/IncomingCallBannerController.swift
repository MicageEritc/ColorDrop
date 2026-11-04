import SwiftUI
import AppKit

/// Native macOS Top-Right Floating Incoming Call HUD Banner (`NSPanel`):
/// Replaces the collapsed system `UNUserNotificationCenter` "选项 ⌄" dropdown with a direct,
/// one-click floating notification banner at the top-right corner of the screen featuring
/// vibrant **Green ("接听")** and **Red ("挂断")** buttons.
@MainActor
public final class IncomingCallBannerController: NSObject {
    public static let shared = IncomingCallBannerController()

    private var bannerPanel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var dismissedCallId: String?
    private var lastPlayedSoundCallId: String?

    private override init() {
        super.init()
    }

    public func updateBanner(for call: IncomingCallItem?, coordinator: ConnectCoordinator) {
        guard let call, call.callState == 4 || call.callState == 3 else {
            dismissBanner()
            dismissedCallId = nil
            return
        }

        // If the user manually closed the floating banner for this specific ringing call, keep it hidden unless state changed to 3
        if dismissedCallId == call.id && call.callState == 4 {
            return
        }

        if call.callState == 4 && lastPlayedSoundCallId != call.id {
            lastPlayedSoundCallId = call.id
            if let sound = NSSound(named: NSSound.Name("Glass")) ?? NSSound(named: NSSound.Name("Tink")) {
                sound.play()
            }
        }

        let content = AnyView(
            IncomingCallFloatingBannerView(
                coordinator: coordinator,
                onCloseBannerOnly: { [weak self] in
                    self?.dismissedCallId = call.id
                    self?.dismissBanner()
                }
            )
            .environment(\.colorScheme, .light)
        )

        if let panel = bannerPanel, let host = hostingView {
            host.rootView = content
            repositionPanelTopRight(panel)
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
            return
        }

        let panelWidth: CGFloat = 396
        let panelHeight: CGFloat = 86
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.appearance = NSAppearance(named: .aqua)

        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        panel.contentView = host

        self.bannerPanel = panel
        self.hostingView = host

        repositionPanelTopRight(panel)
        panel.alphaValue = 0.0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1.0
        }
    }

    public func dismissBanner() {
        guard let panel = bannerPanel else { return }
        panel.orderOut(nil)
    }

    private func repositionPanelTopRight(_ panel: NSPanel) {
        let mouseLoc = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        let visible = screen.visibleFrame
        let width: CGFloat = 396
        let height: CGFloat = 86
        let x = visible.maxX - width - 16
        let y = visible.maxY - height - 12
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
}

private struct IncomingCallFloatingBannerView: View {
    @ObservedObject var coordinator: ConnectCoordinator
    let onCloseBannerOnly: () -> Void

    var body: some View {
        if let call = coordinator.activeIncomingCall {
            ZStack(alignment: .topLeading) {
                HStack(spacing: 12) {
                    // Caller / App Icon Badge
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color(red: 0.14, green: 0.52, blue: 0.98), Color(red: 0.22, green: 0.76, blue: 0.98)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 44, height: 44)

                        Image(systemName: call.callState == 3
                              ? (coordinator.callAudioService.isUsingHeadphones ? "headphones" : "mic.fill")
                              : "phone.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    // Caller Number & Subtitle
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(call.displayTitle)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            if call.callState == 3 {
                                Text(coordinator.callAudioService.formattedCallDuration)
                                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(Color(red: 0.11, green: 0.62, blue: 0.30))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color(red: 0.16, green: 0.78, blue: 0.37).opacity(0.15))
                                    .clipShape(Capsule())
                            }
                        }

                        if call.callState == 3 {
                            Text("通话中 · \(coordinator.callAudioService.activeInputDeviceName)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color(red: 0.11, green: 0.62, blue: 0.30))
                                .lineLimit(1)
                        } else if call.isAnswerPendingOnMac {
                            Text("已请求接听 · 轻按耳机或手机确认")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.blue)
                                .lineLimit(1)
                        } else {
                            Text(call.location.isEmpty ? "手机来电" : "来电 · \(call.location)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 6)

                    // Direct One-Click Green & Red Action Buttons (No Dropdown Needed!)
                    HStack(spacing: 8) {
                        if call.callState == 3 {
                            Button {
                                coordinator.toggleCallMicrophoneMute()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: coordinator.callAudioService.isMicrophoneMuted ? "mic.slash.fill" : "mic.fill")
                                        .font(.system(size: 12, weight: .semibold))
                                    Text(coordinator.callAudioService.isMicrophoneMuted ? "已静音" : "静音")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .foregroundStyle(coordinator.callAudioService.isMicrophoneMuted ? .white : .primary)
                                .padding(.horizontal, 12)
                                .frame(height: 34)
                                .background(
                                    Capsule()
                                        .fill(coordinator.callAudioService.isMicrophoneMuted ? Color.orange : Color.black.opacity(0.07))
                                )
                            }
                            .buttonStyle(.plain)
                        } else {
                            // Direct Green Answer Button
                            Button {
                                coordinator.answerCurrentCallOnMac()
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: coordinator.callAudioService.isUsingHeadphones ? "headphones" : "phone.fill")
                                        .font(.system(size: 12, weight: .bold))
                                    Text("接听")
                                        .font(.system(size: 13, weight: .bold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .frame(height: 34)
                                .background(
                                    Capsule()
                                        .fill(Color(red: 0.16, green: 0.78, blue: 0.37))
                                )
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .help("直接接听并调用 \(coordinator.callAudioService.activeInputDeviceName)")
                        }

                        // Direct Red Hangup Button
                        Button {
                            coordinator.hangupCurrentCall()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "phone.down.fill")
                                    .font(.system(size: 12, weight: .bold))
                                Text("挂断")
                                    .font(.system(size: 13, weight: .bold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(
                                Capsule()
                                    .fill(Color(red: 0.95, green: 0.23, blue: 0.21))
                            )
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("直接挂断电话")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(width: 384, height: 74)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.black.opacity(0.10), lineWidth: 1)
                )
                .padding(.top, 6)
                .padding(.leading, 6)

                // Top-left dismiss (×) button (like macOS Notification Banner)
                Button {
                    onCloseBannerOnly()
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color(red: 0.93, green: 0.93, blue: 0.95))
                            .frame(width: 20, height: 20)
                        Circle()
                            .stroke(Color.black.opacity(0.12), lineWidth: 0.5)
                            .frame(width: 20, height: 20)
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("隐藏横幅")
            }
            .frame(width: 396, height: 86)
        }
    }
}
