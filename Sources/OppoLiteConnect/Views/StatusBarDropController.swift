import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Manages the floating drop zone ("小虚拟窗") near the ColorDrop Menu Bar icon
/// whenever the user drags Mac files toward the top status bar.
/// Dropping files into this mini-window sends them directly to `/storage/emulated/0/Download/ColorDrop`.
@MainActor
public final class StatusBarDropController: ObservableObject {
    public static let shared = StatusBarDropController()

    @Published public var isHoveringDropZone: Bool = false
    @Published public var justDroppedCount: Int = 0

    private var panel: NSPanel?
    private var globalDragMonitor: Any?
    private var globalMouseUpMonitor: Any?
    private var localDragMonitor: Any?
    private var pollTimer: Timer?
    private var lastObservedDragChangeCount: Int = -1
    private var cachedDragHasFiles: Bool = false
    private var isHidingAfterDrop: Bool = false

    private let panelWidth: CGFloat = 256
    private let panelHeight: CGFloat = 88

    private init() {}

    public func startMonitoring() {
        guard pollTimer == nil else { return }

        globalDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateDragState()
            }
        }

        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMouseReleased()
            }
        }

        localDragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            Task { @MainActor [weak self] in
                if event.type == .leftMouseUp {
                    self?.handleMouseReleased()
                } else {
                    self?.evaluateDragState()
                }
            }
            return event
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateDragState()
            }
        }
    }

    private func evaluateDragState() {
        guard !isHidingAfterDrop else { return }

        let mouseDown = (NSEvent.pressedMouseButtons & 1) != 0
        guard mouseDown else {
            if panel?.isVisible == true && !isHoveringDropZone {
                hideDropPanel()
            }
            return
        }

        let pb = NSPasteboard(name: .drag)
        if pb.changeCount != lastObservedDragChangeCount {
            lastObservedDragChangeCount = pb.changeCount
            cachedDragHasFiles = Self.pasteboardContainsFileURLs(pb)
        }

        guard cachedDragHasFiles else {
            hideDropPanel()
            return
        }

        let mouseLoc = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) }) ?? NSScreen.main else {
            return
        }

        // Trigger when cursor is dragged within 135pt of the top Menu Bar, or while inside/near the active drop panel
        let nearTopBar = mouseLoc.y >= (screen.frame.maxY - 135)
        let nearPanel: Bool = {
            guard let panel, panel.isVisible else { return false }
            let expanded = panel.frame.insetBy(dx: -45, dy: -45)
            return expanded.contains(mouseLoc)
        }()

        if nearTopBar || nearPanel {
            showDropPanelIfNeeded(on: screen, mouseLocation: mouseLoc)
        } else {
            hideDropPanel()
        }
    }

    private func handleMouseReleased() {
        guard !isHidingAfterDrop else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, !self.isHidingAfterDrop else { return }
            if (NSEvent.pressedMouseButtons & 1) == 0 {
                self.hideDropPanel()
            }
        }
    }

    private static func pasteboardContainsFileURLs(_ pb: NSPasteboard) -> Bool {
        if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return true
        }
        if let types = pb.types {
            if types.contains(.fileURL) || types.contains(NSPasteboard.PasteboardType("NSFilenamesPboardType")) {
                return true
            }
        }
        return false
    }

    private func showDropPanelIfNeeded(on screen: NSScreen, mouseLocation: NSPoint) {
        if panel == nil {
            createDropPanel()
        }
        guard let panel else { return }

        if !panel.isVisible {
            let anchorX: CGFloat = {
                if let statusWin = NSApplication.shared.windows.first(where: {
                    String(describing: type(of: $0)).contains("StatusBar") && $0.frame.width > 0
                }) {
                    return statusWin.frame.midX - (panelWidth / 2.0)
                }
                return mouseLocation.x - (panelWidth / 2.0)
            }()

            let clampedX = min(
                max(anchorX, screen.visibleFrame.minX + 12),
                screen.visibleFrame.maxX - panelWidth - 12
            )
            let targetY = screen.visibleFrame.maxY - panelHeight - 6
            panel.setFrame(NSRect(x: clampedX, y: targetY, width: panelWidth, height: panelHeight), display: true)
            panel.alphaValue = 0.0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                panel.animator().alphaValue = 1.0
            }
        }
    }

    public func hideDropPanel() {
        isHoveringDropZone = false
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0.0
        }, completionHandler: {
            Task { @MainActor in
                panel.orderOut(nil)
            }
        })
    }

    fileprivate func handleDroppedFileURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isHoveringDropZone = false
        justDroppedCount = urls.count
        isHidingAfterDrop = true

        ConnectCoordinator.shared.sendLocalFilesToPhone(
            urls: urls,
            explicitTargetDirectory: ConnectCoordinator.menuBarDefaultRemoteDirectory
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) { [weak self] in
            guard let self else { return }
            self.justDroppedCount = 0
            self.isHidingAfterDrop = false
            self.hideDropPanel()
        }
    }

    private func createDropPanel() {
        let dropPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        dropPanel.isOpaque = false
        dropPanel.backgroundColor = .clear
        dropPanel.hasShadow = true
        dropPanel.level = .statusBar
        dropPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        dropPanel.isMovable = false

        let containerView = StatusBarDropReceivingView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        let hostingView = NSHostingView(rootView: StatusBarDropFloatingView(controller: self))
        hostingView.frame = containerView.bounds
        hostingView.autoresizingMask = [.width, .height]
        containerView.addSubview(hostingView)

        dropPanel.contentView = containerView
        self.panel = dropPanel
    }
}

/// Native AppKit `NSDraggingDestination` view so Finder file drags are accepted seamlessly even when ColorDrop is in the background.
private final class StatusBarDropReceivingView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([
            .fileURL,
            NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Task { @MainActor in
            StatusBarDropController.shared.isHoveringDropZone = true
        }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        Task { @MainActor in
            StatusBarDropController.shared.isHoveringDropZone = false
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        var urls: [URL] = []

        if let readURLs = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !readURLs.isEmpty {
            urls = readURLs
        } else if let filenames = pb.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            urls = filenames.map { URL(fileURLWithPath: $0) }
        }

        guard !urls.isEmpty else { return false }
        Task { @MainActor in
            StatusBarDropController.shared.handleDroppedFileURLs(urls)
        }
        return true
    }
}

public struct StatusBarDropFloatingView: View {
    @ObservedObject var controller: StatusBarDropController

    public var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        controller.justDroppedCount > 0
                            ? Color.green.opacity(0.16)
                            : (controller.isHoveringDropZone ? Color.blue.opacity(0.20) : Color.blue.opacity(0.12))
                    )
                    .frame(width: 42, height: 42)

                Image(
                    systemName: controller.justDroppedCount > 0
                        ? "checkmark.circle.fill"
                        : (controller.isHoveringDropZone ? "arrow.up.doc.fill" : "paperplane.fill")
                )
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(controller.justDroppedCount > 0 ? .green : .blue)
            }

            VStack(alignment: .leading, spacing: 3) {
                if controller.justDroppedCount > 0 {
                    Text("已发送 \(controller.justDroppedCount) 个文件")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("已保存至 Download/ColorDrop")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text(controller.isHoveringDropZone ? "松开立即发送到手机" : "拖入此处发送到手机")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(controller.isHoveringDropZone ? .blue : .primary)
                    Text("默认保存至 Download/ColorDrop")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(NSColor.windowBackgroundColor).opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    controller.isHoveringDropZone ? Color.blue : Color.black.opacity(0.15),
                    style: StrokeStyle(
                        lineWidth: controller.isHoveringDropZone ? 2.0 : 1.0,
                        dash: controller.isHoveringDropZone ? [6, 4] : []
                    )
                )
        )
        .padding(4)
    }
}
