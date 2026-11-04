import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

/// Manages macOS Call Audio Relay ("电话流转"):
/// - Automatically detects the Mac's current default audio input (microphone) and output devices via CoreAudio.
/// - If headphones (AirPods, Bluetooth headset, wired headset, or USB headset) are connected to the Mac,
///   automatically uses the headphones' microphone and speaker and dynamically follows mid-call route changes.
/// - Captures live microphone audio via `AVAudioEngine`, computes real-time voice level, supports mute/unmute,
///   and coordinates call answer signaling with the connected phone.
@MainActor
public final class CallAudioRelayService: ObservableObject {
    public static let shared = CallAudioRelayService()

    @Published public private(set) var isRelayActive: Bool = false
    @Published public private(set) var isMicrophoneMuted: Bool = false
    @Published public private(set) var activeInputDeviceName: String = "Mac 麦克风"
    @Published public private(set) var activeOutputDeviceName: String = "Mac 扬声器"
    @Published public private(set) var isUsingHeadphones: Bool = false
    @Published public private(set) var micInputLevel: Double = 0.0
    @Published public private(set) var callDurationSeconds: Int = 0

    public var onAudioRouteChanged: ((String, Bool) -> Void)?

    private var audioEngine: AVAudioEngine?
    private var durationTimer: Timer?
    private var callStartTime: Date?
    private var hasInstalledCoreAudioListener = false

    private init() {
        refreshAudioDeviceRoute()
        installCoreAudioRouteListenerIfNeeded()
    }

    // MARK: - CoreAudio Default Input / Output & Headphone Detection

    public func refreshAudioDeviceRoute() {
        let inputInfo = Self.queryAudioDeviceInfo(isInput: true)
        let outputInfo = Self.queryAudioDeviceInfo(isInput: false)

        let headSetConnected = inputInfo.isHeadphoneOrExternal || outputInfo.isHeadphoneOrExternal
        self.isUsingHeadphones = headSetConnected

        if headSetConnected {
            let baseName = !inputInfo.name.isEmpty ? inputInfo.name : (!outputInfo.name.isEmpty ? outputInfo.name : "外接耳机")
            if baseName.contains("麦克风") || baseName.contains("耳机") || baseName.lowercased().contains("airpods") {
                self.activeInputDeviceName = baseName
            } else {
                self.activeInputDeviceName = "\(baseName) 耳机麦克风"
            }
        } else {
            self.activeInputDeviceName = inputInfo.name.isEmpty ? "Mac 内置麦克风" : inputInfo.name
        }
        self.activeOutputDeviceName = outputInfo.name.isEmpty ? "Mac 扬声器" : outputInfo.name
        onAudioRouteChanged?(self.activeInputDeviceName, self.isUsingHeadphones)
    }

    public nonisolated static func queryAudioDeviceInfo(isInput: Bool) -> (name: String, isHeadphoneOrExternal: Bool) {
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
            return (isInput ? "Mac 麦克风" : "Mac 扬声器", false)
        }

        // 1. Read Device Name
        var nameCF: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let nameStatus = withUnsafeMutablePointer(to: &nameCF) { ptr in
            AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, ptr)
        }
        let deviceName = (nameStatus == noErr) ? (nameCF as String).trimmingCharacters(in: .whitespacesAndNewlines) : ""

        // 2. Read Transport Type (Bluetooth / BluetoothLE / USB / Headphones)
        var transportType: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        var transportAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectGetPropertyData(deviceID, &transportAddr, 0, nil, &transportSize, &transportType)

        let lowerName = deviceName.lowercased()
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
            || deviceName.contains("耳机")
            || deviceName.contains("耳麦")

        return (deviceName, isBT || isUSB || isHeadphoneKeyword)
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
                self.refreshAudioDeviceRoute()
                if self.isRelayActive {
                    self.rebindMicrophoneEngineIfNeeded()
                }
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

    // MARK: - Start / Stop Mac Call Audio & Microphone Relay

    public func startCallRelay(phoneIP: String) {
        refreshAudioDeviceRoute()
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

        // Trigger Android / ColorOS call answer via ADB if available on the local machine
        Task.detached(priority: .userInitiated) {
            Self.tryAnswerCallViaADBIfAvailable(phoneIP: phoneIP)
        }

        requestMicPermissionAndStartEngine()
    }

    public func stopCallRelay() {
        durationTimer?.invalidate()
        durationTimer = nil
        callStartTime = nil
        callDurationSeconds = 0
        micInputLevel = 0.0
        isMicrophoneMuted = false
        isRelayActive = false

        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
    }

    public func toggleMicrophoneMute() {
        isMicrophoneMuted.toggle()
        if isMicrophoneMuted {
            micInputLevel = 0.0
        }
    }

    public var formattedCallDuration: String {
        let mins = callDurationSeconds / 60
        let secs = callDurationSeconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private func requestMicPermissionAndStartEngine() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            startAVAudioEngineTap()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard granted else { return }
                Task { @MainActor [weak self] in
                    self?.startAVAudioEngineTap()
                }
            }
        default:
            break
        }
    }

    private func rebindMicrophoneEngineIfNeeded() {
        guard isRelayActive else { return }
        startAVAudioEngineTap()
    }

    private func startAVAudioEngineTap() {
        if let existing = audioEngine {
            existing.inputNode.removeTap(onBus: 0)
            existing.stop()
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }

            var sumSquares: Float = 0.0
            for i in 0..<frameLength {
                let sample = channelData[i]
                sumSquares += sample * sample
            }
            let rms = sqrt(sumSquares / Float(frameLength))
            let normalizedLevel = min(1.0, Double(rms * 8.5))

            Task { @MainActor [weak self] in
                guard let self, self.isRelayActive else { return }
                if self.isMicrophoneMuted {
                    self.micInputLevel = 0.0
                } else {
                    self.micInputLevel = normalizedLevel
                }
            }
        }

        do {
            engine.prepare()
            try engine.start()
            self.audioEngine = engine
        } catch {
            self.audioEngine = nil
        }
    }

    private nonisolated static func tryAnswerCallViaADBIfAvailable(phoneIP: String) {
        let adbCandidates = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb", "/usr/bin/adb"]
        guard let adbPath = adbCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return
        }
        // Send telecom accept-ringing-call and KEYCODE_CALL (5)
        for args in [["shell", "cmd", "telecom", "accept-ringing-call"], ["shell", "input", "keyevent", "5"]] {
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
