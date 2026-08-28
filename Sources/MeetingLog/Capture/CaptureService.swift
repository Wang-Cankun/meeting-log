@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import AppKit
import Foundation

struct CaptureApplication: Identifiable, Equatable {
    let bundleIdentifier: String
    let name: String
    var id: String { bundleIdentifier }
}

@MainActor
final class CaptureService: NSObject, SCContentSharingPickerObserver, SCStreamDelegate, SCStreamOutput, SCRecordingOutputDelegate {
    private var screenFilter: SCContentFilter?
    private var audioStream: SCStream?
    private var videoStream: SCStream?
    private var recordingOutputs: [SCRecordingOutput] = []
    private var unfinishedOutputs: Set<ObjectIdentifier> = []
    private var recordingFinish: CheckedContinuation<Void, any Error>?
    private var recordingError: Error?
    private var isPreviewing = false
    private let systemAudioQueue = DispatchQueue(label: "meeting-log.system-audio")
    private let microphoneQueue = DispatchQueue(label: "meeting-log.microphone")

    var onScreenSelection: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onSystemAudioLevel: ((Float) -> Void)?
    var onMicrophoneLevel: ((Float) -> Void)?

    var hasScreenSource: Bool { screenFilter != nil }

    override init() {
        super.init()
        let picker = SCContentSharingPicker.shared
        var configuration = picker.defaultConfiguration
        configuration.allowedPickerModes = [.singleDisplay, .singleWindow, .singleApplication]
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
    }

    deinit {
        SCContentSharingPicker.shared.remove(self)
    }

    func chooseScreen() {
        SCContentSharingPicker.shared.present()
    }

    func availableApplications() async throws -> [CaptureApplication] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownBundleID = Bundle.main.bundleIdentifier
        return Dictionary(grouping: content.applications.compactMap { application -> CaptureApplication? in
            guard !application.bundleIdentifier.isEmpty,
                  application.bundleIdentifier != ownBundleID,
                  !application.applicationName.isEmpty
            else { return nil }
            return CaptureApplication(bundleIdentifier: application.bundleIdentifier, name: application.applicationName)
        }, by: \.bundleIdentifier)
        .compactMap { $0.value.first }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func startPreview(applicationBundleID: String?) async throws {
        guard audioStream == nil else { return }
        let filter = try await audioFilter(applicationBundleID: applicationBundleID)
        let configuration = audioConfiguration(microphoneID: nil, microphoneEnabled: false)
        configuration.queueDepth = 1

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemAudioQueue)
        audioStream = stream
        isPreviewing = true
        do { try await stream.startCapture() }
        catch {
            audioStream = nil
            isPreviewing = false
            throw error
        }
    }

    func stopPreview() async {
        guard isPreviewing, let audioStream else { return }
        do { try await audioStream.stopCapture() }
        catch { onError?(error.localizedDescription) }
        self.audioStream = nil
        isPreviewing = false
        onSystemAudioLevel?(0)
    }

    func start(
        audioOutputURL: URL,
        screenOutputURL: URL?,
        applicationBundleID: String?,
        microphoneID: String?,
        microphoneEnabled: Bool
    ) async throws {
        guard audioStream == nil, videoStream == nil else { throw CaptureError.alreadyCapturing }
        if screenOutputURL != nil, screenFilter == nil { throw CaptureError.noScreenSource }

        let audioStream: SCStream
        do {
            let filter = try await audioFilter(applicationBundleID: applicationBundleID)
            audioStream = try recordingStream(
                filter: filter,
                configuration: audioConfiguration(microphoneID: microphoneID, microphoneEnabled: microphoneEnabled),
                outputURL: audioOutputURL,
                monitorsAudio: true,
                monitorsMicrophone: microphoneEnabled
            )
            self.audioStream = audioStream

            if let screenOutputURL, let screenFilter {
                let configuration = SCStreamConfiguration()
                configuration.capturesAudio = false
                configuration.width = 1920
                configuration.height = 1080
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 10)
                configuration.queueDepth = 3
                videoStream = try recordingStream(
                    filter: screenFilter,
                    configuration: configuration,
                    outputURL: screenOutputURL,
                    monitorsAudio: false,
                    monitorsMicrophone: false
                )
            }
        } catch {
            resetStreams()
            throw error
        }

        do {
            try await audioStream.startCapture()
            try await videoStream?.startCapture()
        } catch {
            try? await audioStream.stopCapture()
            try? await videoStream?.stopCapture()
            resetStreams()
            throw error
        }
    }

    func stop() async throws {
        let streams = [audioStream, videoStream].compactMap { $0 }
        guard !streams.isEmpty else { return }
        defer {
            resetStreams()
            onSystemAudioLevel?(0)
            onMicrophoneLevel?(0)
        }

        try await withCheckedThrowingContinuation { continuation in
            recordingFinish = continuation
            Task {
                do {
                    for stream in streams { try await stream.stopCapture() }
                    finishRecordingIfPossible()
                } catch {
                    finishRecording(throwing: error)
                }
            }
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            screenFilter = filter
            onScreenSelection?(Self.sourceName(for: filter))
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {}

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor in onError?(error.localizedDescription) }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor in onError?(error.localizedDescription) }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio || type == .microphone else { return }
        let value = Self.level(from: sampleBuffer)
        Task { @MainActor in
            if type == .audio { onSystemAudioLevel?(value) }
            else { onMicrophoneLevel?(value) }
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        Task { @MainActor in
            recordingError = error
            unfinishedOutputs.remove(ObjectIdentifier(recordingOutput))
            onError?(error.localizedDescription)
            finishRecordingIfPossible()
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            unfinishedOutputs.remove(ObjectIdentifier(recordingOutput))
            finishRecordingIfPossible()
        }
    }

    private func recordingStream(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        outputURL: URL,
        monitorsAudio: Bool,
        monitorsMicrophone: Bool
    ) throws -> SCStream {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        if monitorsAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemAudioQueue)
        }
        if monitorsMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: microphoneQueue)
        }

        let outputConfiguration = SCRecordingOutputConfiguration()
        outputConfiguration.outputURL = outputURL
        outputConfiguration.outputFileType = .mov
        guard outputConfiguration.availableVideoCodecTypes.contains(.hevc) else { throw CaptureError.hevcUnavailable }
        outputConfiguration.videoCodecType = .hevc
        let output = SCRecordingOutput(configuration: outputConfiguration, delegate: self)
        try stream.addRecordingOutput(output)
        recordingOutputs.append(output)
        unfinishedOutputs.insert(ObjectIdentifier(output))
        return stream
    }

    private func audioConfiguration(microphoneID: String?, microphoneEnabled: Bool) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.captureMicrophone = microphoneEnabled
        configuration.microphoneCaptureDeviceID = microphoneEnabled ? microphoneID : nil
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        return configuration
    }

    private func audioFilter(applicationBundleID: String?) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        guard let applicationBundleID else {
            return SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        }
        guard let application = content.applications.first(where: { $0.bundleIdentifier == applicationBundleID }) else {
            throw CaptureError.applicationUnavailable
        }
        return SCContentFilter(display: display, including: [application], exceptingWindows: [])
    }

    private func finishRecordingIfPossible() {
        guard unfinishedOutputs.isEmpty else { return }
        if let recordingError { finishRecording(throwing: recordingError) }
        else {
            recordingFinish?.resume()
            recordingFinish = nil
        }
    }

    private func finishRecording(throwing error: Error) {
        recordingFinish?.resume(throwing: error)
        recordingFinish = nil
    }

    private func resetStreams() {
        audioStream = nil
        videoStream = nil
        recordingOutputs = []
        unfinishedOutputs = []
        recordingError = nil
        isPreviewing = false
    }

    nonisolated private static func level(from sampleBuffer: CMSampleBuffer) -> Float {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format),
              let block = CMSampleBufferGetDataBuffer(sampleBuffer)
        else { return 0 }

        var length = 0
        var totalLength = 0
        var bytes: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: &totalLength, dataPointerOut: &bytes) == kCMBlockBufferNoErr,
              let bytes, totalLength > 0
        else { return 0 }

        let rms: Float
        if description.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            let values = UnsafeRawPointer(bytes).assumingMemoryBound(to: Float.self)
            let count = totalLength / MemoryLayout<Float>.size
            guard count > 0 else { return 0 }
            var sum: Float = 0
            for index in 0..<count { sum += values[index] * values[index] }
            rms = sqrt(sum / Float(count))
        } else {
            let values = UnsafeRawPointer(bytes).assumingMemoryBound(to: Int16.self)
            let count = totalLength / MemoryLayout<Int16>.size
            guard count > 0 else { return 0 }
            var sum: Float = 0
            for index in 0..<count {
                let value = Float(values[index]) / Float(Int16.max)
                sum += value * value
            }
            rms = sqrt(sum / Float(count))
        }
        let decibels = 20 * log10(max(rms, 0.000_001))
        return max(0, min(1, (decibels + 60) / 60))
    }

    private static func sourceName(for filter: SCContentFilter) -> String {
        if let window = filter.includedWindows.first {
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let application = window.owningApplication?.applicationName ?? "Window"
            return title.isEmpty ? application : "\(application): \(title)"
        }
        if let application = filter.includedApplications.first {
            return application.applicationName
        }
        if let display = filter.includedDisplays.first {
            let screen = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
            }
            return screen?.localizedName ?? "Display \(display.displayID)"
        }
        return "Selected source"
    }
}

enum CaptureError: LocalizedError {
    case noDisplay
    case noScreenSource
    case applicationUnavailable
    case alreadyCapturing
    case hevcUnavailable

    var errorDescription: String? {
        switch self {
        case .noDisplay: "No display is available for system audio capture."
        case .noScreenSource: "Choose a screen source or turn off Record Screen."
        case .applicationUnavailable: "The selected application is not available."
        case .alreadyCapturing: "Audio capture is already running."
        case .hevcUnavailable: "HEVC recording is unavailable on this Mac."
        }
    }
}
