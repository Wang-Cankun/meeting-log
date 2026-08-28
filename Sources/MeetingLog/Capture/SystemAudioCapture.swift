@preconcurrency import AVFoundation
import AppKit
import AudioToolbox
import CoreAudio
import Foundation

final class SystemAudioCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "meeting-log.system-audio", qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var audioFile: AVAudioFile?
    private var levelGate = LevelUpdateGate()
    private var writeError: (any Error)?

    var onLevel: (@Sendable (Float) -> Void)?

    static func applications() -> [CaptureApplication] {
        let ownBundleID = Bundle.main.bundleIdentifier
        return Dictionary(grouping: NSWorkspace.shared.runningApplications.compactMap { application -> CaptureApplication? in
            guard application.activationPolicy == .regular,
                  let bundleIdentifier = application.bundleIdentifier,
                  bundleIdentifier != ownBundleID,
                  let name = application.localizedName,
                  !name.isEmpty
            else { return nil }
            return CaptureApplication(bundleIdentifier: bundleIdentifier, name: name)
        }, by: \.bundleIdentifier)
        .compactMap { $0.value.first }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func start(applicationBundleID: String?, outputURL: URL?) throws {
        guard tapID == kAudioObjectUnknown else { throw SystemAudioError.alreadyCapturing }
        writeError = nil

        let description: CATapDescription
        if let applicationBundleID {
            description = CATapDescription(stereoMixdownOfProcesses: [])
            description.bundleIDs = [applicationBundleID]
            description.isProcessRestoreEnabled = true
        } else {
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        }
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        do {
            try check(AudioHardwareCreateProcessTap(description, &tapID), operation: "create system audio tap")
            var streamDescription: AudioStreamBasicDescription = try read(
                objectID: tapID,
                selector: kAudioTapPropertyFormat,
                defaultValue: AudioStreamBasicDescription()
            )
            guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
                throw SystemAudioError.invalidFormat
            }

            let outputDevice = try defaultOutputDevice()
            let outputUID: String = try read(
                objectID: outputDevice,
                selector: kAudioDevicePropertyDeviceUID,
                defaultValue: "" as CFString
            ) as String
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "MeetingLog Audio Tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]],
            ]
            try check(
                AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateDeviceID),
                operation: "create system audio device"
            )

            if let outputURL {
                if FileManager.default.fileExists(atPath: outputURL.path) {
                    try FileManager.default.removeItem(at: outputURL)
                }
                audioFile = try AVAudioFile(
                    forWriting: outputURL,
                    settings: format.settings,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: format.isInterleaved
                )
            }

            try check(
                AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, queue) { [weak self] _, inputData, _, _, _ in
                    guard let self,
                          let buffer = AVAudioPCMBuffer(
                              pcmFormat: format,
                              bufferListNoCopy: inputData,
                              deallocator: nil
                          )
                    else { return }
                    if self.writeError == nil {
                        do { try self.audioFile?.write(from: buffer) }
                        catch { self.writeError = error }
                    }
                    if self.levelGate.shouldPublish(at: DispatchTime.now().uptimeNanoseconds) {
                        self.onLevel?(Self.level(from: buffer))
                    }
                },
                operation: "prepare system audio"
            )
            try check(AudioDeviceStart(aggregateDeviceID, ioProcID), operation: "start system audio")
        } catch {
            try? stop()
            throw error
        }
    }

    func stop() throws {
        if aggregateDeviceID != kAudioObjectUnknown {
            _ = AudioDeviceStop(aggregateDeviceID, ioProcID)
            if let ioProcID {
                _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            }
        }
        ioProcID = nil
        audioFile = nil
        if aggregateDeviceID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        levelGate.reset()
        onLevel?(0)
        if let writeError {
            self.writeError = nil
            throw writeError
        }
    }

    deinit { try? stop() }

    private func defaultOutputDevice() throws -> AudioObjectID {
        try read(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            defaultValue: AudioObjectID(kAudioObjectUnknown)
        )
    }

    private func read<T>(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        defaultValue: T
    ) throws -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = defaultValue
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
        }
        try check(status, operation: "read system audio property")
        return value
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            if status == kAudioDevicePermissionsError { throw SystemAudioError.permissionRequired }
            throw SystemAudioError.operationFailed(operation, status)
        }
    }

    private static func level(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return 0 }
        var sum: Float = 0
        for channel in 0..<channelCount {
            for frame in 0..<frameCount {
                let value = channels[channel][frame]
                sum += value * value
            }
        }
        let rms = sqrt(sum / Float(frameCount * channelCount))
        let decibels = 20 * log10(max(rms, 0.000_001))
        return max(0, min(1, (decibels + 60) / 60))
    }
}

enum SystemAudioError: LocalizedError {
    case alreadyCapturing
    case permissionRequired
    case invalidFormat
    case operationFailed(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .alreadyCapturing:
            "System audio capture is already running."
        case .permissionRequired:
            "System audio permission is required. Enable MeetingLog in Privacy & Security."
        case .invalidFormat:
            "The selected system audio source has an unsupported format."
        case let .operationFailed(operation, status):
            "Could not \(operation) (Core Audio error \(status))."
        }
    }
}
