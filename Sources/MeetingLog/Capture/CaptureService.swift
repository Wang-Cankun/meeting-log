@preconcurrency import ScreenCaptureKit
import AppKit
import Foundation

struct CaptureApplication: Identifiable, Equatable {
    let bundleIdentifier: String
    let name: String
    var id: String { bundleIdentifier }
}

@MainActor
final class CaptureService: NSObject, SCContentSharingPickerObserver, SCStreamDelegate, SCRecordingOutputDelegate {
    private var screenFilter: SCContentFilter?
    private var videoStream: SCStream?
    private var videoOutput: SCRecordingOutput?
    private var recordingFinish: CheckedContinuation<Void, any Error>?
    private var recordingError: Error?
    private var isPreviewing = false
    private let systemAudio = SystemAudioCapture()
    private var systemAudioGeneration: UUID?
    private var systemAudioFailed = false

    var onScreenSelection: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onSystemAudioLevel: ((Float) -> Void)?

    override init() {
        super.init()
        systemAudio.onLevel = { [weak self] generation, value in
            Task { @MainActor in self?.receiveSystemAudioLevel(value, generation: generation) }
        }
        systemAudio.onWriteFailure = { [weak self] generation, message in
            Task { @MainActor in self?.receiveSystemAudioFailure(message, generation: generation) }
        }
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

    func startPreview(applicationBundleID: String?) async throws {
        guard !isPreviewing else { return }
        try startSystemAudio(applicationBundleID: applicationBundleID, outputURL: nil)
        isPreviewing = true
    }

    func stopPreview() {
        guard isPreviewing else { return }
        invalidateSystemAudioCallbacks()
        try? systemAudio.stop()
        isPreviewing = false
    }

    func start(
        systemAudioOutputURL: URL,
        screenOutputURL: URL?,
        applicationBundleID: String?
    ) async throws {
        guard videoStream == nil, !isPreviewing else { throw CaptureError.alreadyCapturing }
        if screenOutputURL != nil, screenFilter == nil { throw CaptureError.noScreenSource }

        do {
            try startSystemAudio(applicationBundleID: applicationBundleID, outputURL: systemAudioOutputURL)
            if let screenOutputURL, let screenFilter {
                let configuration = SCStreamConfiguration()
                configuration.capturesAudio = false
                configuration.width = 1920
                configuration.height = 1080
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 10)
                configuration.queueDepth = 3

                let stream = SCStream(filter: screenFilter, configuration: configuration, delegate: self)
                let outputConfiguration = SCRecordingOutputConfiguration()
                outputConfiguration.outputURL = screenOutputURL
                outputConfiguration.outputFileType = .mov
                guard outputConfiguration.availableVideoCodecTypes.contains(.hevc) else {
                    throw CaptureError.hevcUnavailable
                }
                outputConfiguration.videoCodecType = .hevc
                let output = SCRecordingOutput(configuration: outputConfiguration, delegate: self)
                try stream.addRecordingOutput(output)
                videoStream = stream
                videoOutput = output
                try await stream.startCapture()
            }
        } catch {
            invalidateSystemAudioCallbacks()
            try? systemAudio.stop()
            try? await videoStream?.stopCapture()
            resetRecording()
            throw error
        }
    }

    func stop() async throws {
        invalidateSystemAudioCallbacks()
        var stopError: (any Error)?
        do { try systemAudio.stop() }
        catch { stopError = error }
        guard let videoStream else {
            resetRecording()
            if let stopError { throw stopError }
            return
        }

        do {
            try await withCheckedThrowingContinuation { continuation in
                recordingFinish = continuation
                Task {
                    do {
                        try await videoStream.stopCapture()
                        finishRecordingIfPossible()
                    } catch {
                        finishRecording(throwing: error)
                    }
                }
            }
        } catch {
            stopError = stopError ?? error
        }
        resetRecording()
        if let stopError { throw stopError }
    }

    private func startSystemAudio(applicationBundleID: String?, outputURL: URL?) throws {
        let generation = beginSystemAudioCallbacks()
        do {
            try systemAudio.start(applicationBundleID: applicationBundleID, outputURL: outputURL, generation: generation)
        } catch {
            invalidateSystemAudioCallbacks()
            throw error
        }
    }

    private func beginSystemAudioCallbacks() -> UUID {
        let generation = UUID()
        systemAudioGeneration = generation
        systemAudioFailed = false
        return generation
    }

    private func invalidateSystemAudioCallbacks() {
        systemAudioGeneration = nil
        onSystemAudioLevel?(0)
    }

    private func receiveSystemAudioLevel(_ value: Float, generation: UUID) {
        guard systemAudioGeneration == generation, !systemAudioFailed else { return }
        onSystemAudioLevel?(value)
    }

    private func receiveSystemAudioFailure(_ message: String, generation: UUID) {
        guard systemAudioGeneration == generation, !systemAudioFailed else { return }
        systemAudioFailed = true
        onSystemAudioLevel?(0)
        onError?(message)
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
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
        Task { @MainActor in
            recordingError = error
            onError?(error.localizedDescription)
            finishRecordingIfPossible()
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        Task { @MainActor in
            recordingError = error
            videoOutput = nil
            onError?(error.localizedDescription)
            finishRecordingIfPossible()
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            videoOutput = nil
            finishRecordingIfPossible()
        }
    }

    private func finishRecordingIfPossible() {
        guard videoOutput == nil else { return }
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

    private func resetRecording() {
        videoStream = nil
        videoOutput = nil
        recordingError = nil
        isPreviewing = false
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
    case noScreenSource
    case alreadyCapturing
    case hevcUnavailable
    case recordingFailed(String)

    var errorDescription: String? {
        switch self {
        case .noScreenSource: "Choose a screen source or turn off Record Screen."
        case .alreadyCapturing: "Audio capture is already running."
        case .hevcUnavailable: "HEVC recording is unavailable on this Mac."
        case let .recordingFailed(message): message
        }
    }
}
