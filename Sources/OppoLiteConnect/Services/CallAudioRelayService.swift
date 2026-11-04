import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

/// Manages macOS Call Audio Routing & Headphone / Microphone Binding:
/// - Uses 100% exception-free CoreAudio C APIs (`AudioObjectGetPropertyData` / `AudioObjectSetPropertyData`)
///   with proper `Unmanaged<CFString>` ARC bridging (never calling `AVAudioEngine.inputNode.installTap`,
///   which can throw uncaught Objective-C `NSException`s during Bluetooth AirPods A2DP <-> HFP sample rate switches).
/// - Automatically detects connected headphones (AirPods, Bluetooth headset, wired headset, USB headset),
///   prefers the headphone microphone & speaker when active, and supports hardware input mute toggling.
@MainActor
public final class CallAudioRelayService: ObservableObject {
    public static let shared = CallAudioRelayService()

    @Published public private(set) var isRelayActive: Bool = false
    @Published public private(set) var isMicrophoneMuted: Bool = false
    @Published public private(set) var activeInputDeviceName: String = "Mac 麦克风"
    @Published public private(set) var activeOutputDeviceName: String = "Mac 扬声器"
    @Published public private(set) var isUsingHeadphones: Bool = false
    @Published public private(set) var callDurationSeconds: Int = 0

    public var onAudioRouteChanged: ((String, Bool) -> Void)?

    private var durationTimer: Timer?
    private var callStartTime: Date?
    private var hasInstalledCoreAudioListener = false
    private var routeListenerDebounceWorkItem: DispatchWorkItem?

    private init() {
        refreshAudioDeviceRoute()
        installCoreAudioRouteListenerIfNeeded()
    }

    // MARK: - CoreAudio Default Input / Output & Headphone Detection (100% ARC-Safe)

    public func refreshAudioDeviceRoute() {
        let inputInfo = Self.queryAudioDeviceInfo(isInput: true)
        let outputInfo = Self.queryAudioDeviceInfo(isInput: false)

        let headSetConnected = inputInfo.isHeadphoneOrExternal || outputInfo.isHeadphoneOrExternal
        self.isUsingHeadphones = headSetConnected

        if headSetConnected {
            let preferredName = outputInfo.isHeadphoneOrExternal && !outputInfo.name.isEmpty
                ? outputInfo.name
                : (!inputInfo.name.isEmpty ? inputInfo.name : "外接耳机")
            self.activeInputDeviceName = preferredName
        } else {
            self.activeInputDeviceName = inputInfo.name.isEmpty ? "Mac 内置麦克风" : inputInfo.name
        }
        self.activeOutputDeviceName = outputInfo.name.isEmpty ? "Mac 扬声器" : outputInfo.name
        onAudioRouteChanged?(self.activeInputDeviceName, self.isUsingHeadphones)
    }

    public nonisolated static func queryAudioDeviceInfo(isInput: Bool) -> (id: AudioDeviceID, name: String, isHeadphoneOrExternal: Bool) {
        var deviceID = AudioDeviceID(0)
        var propSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: isInput ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propSize,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return (0, isInput ? "Mac 麦克风" : "Mac 扬声器", false)
        }

        let deviceName = readDeviceNameSafely(deviceID: deviceID)
        let transportType = readTransportType(deviceID: deviceID)
        let isExternal = classifyHeadphoneOrExternal(name: deviceName, transportType: transportType)
        return (deviceID, deviceName, isExternal)
    }

    /// Reads `kAudioObjectPropertyName` using `Unmanaged<CFString>?` so Swift ARC never double-frees or corrupts memory.
    private nonisolated static func readDeviceNameSafely(deviceID: AudioDeviceID) -> String {
        var unmanagedName: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &unmanagedName) { ptr in
            AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, ptr)
        }
        guard status == noErr, let cfStr = unmanagedName?.takeRetainedValue() else {
            return ""
        }
        return (cfStr as String).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func readTransportType(deviceID: AudioDeviceID) -> UInt32 {
        var transportType: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        var transportAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectGetPropertyData(deviceID, &transportAddr, 0, nil, &transportSize, &transportType)
        return transportType
    }

    private nonisolated static func classifyHeadphoneOrExternal(name: String, transportType: UInt32) -> Bool {
        let lowerName = name.lowercased()
        let isBT = (transportType == kAudioDeviceTransportTypeBluetooth)
            || (transportType == kAudioDeviceTransportTypeBluetoothLE)
        let isUSB = (transportType == kAudioDeviceTransportTypeUSB)
        let isHeadphoneKeyword = lowerName.contains("airpods")
            || lowerName.contains("headphone")
            || lowerName.contains("headset")
            || lowerName.contains("earphone")
            || lowerName.contains("buds")
            || lowerName.contains("beats")
            || lowerName.contains("sony")
            || lowerName.contains("bose")
            || name.contains("耳机")
            || name.contains("耳麦")
        return isBT || isUSB || isHeadphoneKeyword
    }

    /// Ensures that if headphones (e.g. AirPods Pro) are currently the active output device,
    /// their matching microphone input device is also selected as the default macOS input device.
    public nonisolated static func bindHeadphoneMicrophoneAsDefaultInputIfNeeded() {
        let outputInfo = queryAudioDeviceInfo(isInput: false)
        let inputInfo = queryAudioDeviceInfo(isInput: true)
        guard outputInfo.isHeadphoneOrExternal, !inputInfo.isHeadphoneOrExternal else {
            setHardwareInputMute(deviceID: inputInfo.id, muted: false)
            return
        }

        // Enumerate all audio devices to find the input device matching the connected headphones
        var propAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propAddress, 0, nil, &dataSize) == noErr,
              dataSize > 0 else {
            return
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propAddress, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return
        }

        for candidateID in deviceIDs where hasInputChannels(deviceID: candidateID) {
            let name = readDeviceNameSafely(deviceID: candidateID)
            let transport = readTransportType(deviceID: candidateID)
            if name == outputInfo.name || classifyHeadphoneOrExternal(name: name, transportType: transport) {
                var mutableID = candidateID
                var defaultInputAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDefaultInputDevice,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                _ = AudioObjectSetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &defaultInputAddr,
                    0,
                    nil,
                    UInt32(MemoryLayout<AudioDeviceID>.size),
                    &mutableID
                )
                setHardwareInputMute(deviceID: candidateID, muted: false)
                break
            }
        }
    }

    private nonisolated static func hasInputChannels(deviceID: AudioDeviceID) -> Bool {
        var streamAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &streamAddr, 0, nil, &size)
        return status == noErr && size > 0
    }

    private nonisolated static func setHardwareInputMute(deviceID: AudioDeviceID, muted: Bool) {
        guard deviceID != 0, deviceID != kAudioObjectUnknown else { return }
        var muteVal: UInt32 = muted ? 1 : 0
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var isSettable: DarwinBoolean = false
        if AudioObjectIsPropertySettable(deviceID, &muteAddr, &isSettable) == noErr, isSettable.boolValue {
            _ = AudioObjectSetPropertyData(
                deviceID,
                &muteAddr,
                0,
                nil,
                UInt32(MemoryLayout<UInt32>.size),
                &muteVal
            )
        }
    }

    private func installCoreAudioRouteListenerIfNeeded() {
        guard !hasInstalledCoreAudioListener else { return }
        hasInstalledCoreAudioListener = true

        var inputAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var outputAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.routeListenerDebounceWorkItem?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.refreshAudioDeviceRoute()
                    }
                }
                self.routeListenerDebounceWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
            }
        }

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &inputAddr,
            DispatchQueue.main,
            block
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &outputAddr,
            DispatchQueue.main,
            block
        )
    }

    // MARK: - Prepare Audio Route & Start / Stop Call Session

    /// Prepares the Mac's microphone / headphone input route and attempts to answer the ringing call on the phone.
    public func prepareAndRequestCallAnswer(phoneIP: String) {
        Self.bindHeadphoneMicrophoneAsDefaultInputIfNeeded()
        refreshAudioDeviceRoute()
        isMicrophoneMuted = false

        Task.detached(priority: .userInitiated) {
            Self.tryAnswerCallViaADBIfAvailable(phoneIP: phoneIP)
        }
    }

    /// Starts the active in-call session timer once the call is confirmed active (`callState == 3`).
    public func startActiveCallSession(phoneIP: String) {
        Self.bindHeadphoneMicrophoneAsDefaultInputIfNeeded()
        refreshAudioDeviceRoute()
        if !isRelayActive {
            isRelayActive = true
            isMicrophoneMuted = false
            callStartTime = Date()
            callDurationSeconds = 0

            durationTimer?.invalidate()
            durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let start = self.callStartTime else { return }
                    self.callDurationSeconds = max(0, Int(Date().timeIntervalSince(start)))
                }
            }
        }
    }

    public func stopCallRelay() {
        durationTimer?.invalidate()
        durationTimer = nil
        callStartTime = nil
        callDurationSeconds = 0
        if isMicrophoneMuted {
            let inputInfo = Self.queryAudioDeviceInfo(isInput: true)
            Self.setHardwareInputMute(deviceID: inputInfo.id, muted: false)
        }
        isMicrophoneMuted = false
        isRelayActive = false
    }

    public func toggleMicrophoneMute() {
        isMicrophoneMuted.toggle()
        let inputInfo = Self.queryAudioDeviceInfo(isInput: true)
        Self.setHardwareInputMute(deviceID: inputInfo.id, muted: isMicrophoneMuted)
    }

    public var formattedCallDuration: String {
        let mins = callDurationSeconds / 60
        let secs = callDurationSeconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private nonisolated static func tryAnswerCallViaADBIfAvailable(phoneIP: String) {
        let adbCandidates = [
            "/tmp/oppolite-oppodat/adb",
            Bundle.main.bundlePath + "/Contents/Resources/Vendor/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "/usr/bin/adb"
        ]
        guard let adbPath = adbCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return
        }
        let cleanIP = phoneIP.split(separator: ":").first.map(String.init) ?? ""
        if !cleanIP.isEmpty && !cleanIP.hasPrefix("*") && cleanIP != "127.0.0.1" {
            let connectTask = Process()
            connectTask.executableURL = URL(fileURLWithPath: adbPath)
            connectTask.arguments = ["connect", "\(cleanIP):5555"]
            connectTask.standardOutput = FileHandle.nullDevice
            connectTask.standardError = FileHandle.nullDevice
            try? connectTask.run()
            connectTask.waitUntilExit()
        }
        for args in [
            ["shell", "cmd", "telecom", "accept-ringing-call"],
            ["shell", "input", "keyevent", "5"],
            ["shell", "input", "keyevent", "79"]
        ] {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: adbPath)
            task.arguments = args
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()
            task.waitUntilExit()
        }
    }
}
