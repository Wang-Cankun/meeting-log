@preconcurrency import AVFoundation
import Foundation

@MainActor
final class MicrophoneCapture: NSObject, AVCaptureFileOutputRecordingDelegate {
    private let session = AVCaptureSession()
    private let dataOutput = AVCaptureAudioDataOutput()
    private let fileOutput = AVCaptureAudioFileOutput()
    private var timer: Timer?
    private var finish: CheckedContinuation<Void, any Error>?
    private var recordingError: Error?
    var onLevel: ((Float) -> Void)?

    static var devices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    func start(deviceID: String?) throws {
        stopPreview()
        guard let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .audio) else {
            throw MicrophoneError.noMicrophone
        }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(dataOutput), session.canAddOutput(fileOutput) else {
            session.commitConfiguration()
            throw MicrophoneError.unavailable
        }
        session.addInput(input)
        session.addOutput(dataOutput)
        session.addOutput(fileOutput)
        fileOutput.audioSettings = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ]
        session.commitConfiguration()
        session.startRunning()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                let db = self?.dataOutput.connection(with: .audio)?.audioChannels.first?.averagePowerLevel ?? -60
                self?.onLevel?(max(0, min(1, (db + 60) / 60)))
            }
        }
    }

    func startRecording(to outputURL: URL, deviceID: String?) throws {
        try start(deviceID: deviceID)
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        recordingError = nil
        fileOutput.startRecording(to: outputURL, outputFileType: .m4a, recordingDelegate: self)
    }

    func stopPreview() {
        guard !fileOutput.isRecording else { return }
        stopSession()
    }

    func stopRecording() async throws {
        defer { stopSession() }
        guard fileOutput.isRecording else {
            if let recordingError {
                self.recordingError = nil
                throw recordingError
            }
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            finish = continuation
            fileOutput.stopRecording()
        }
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: (any Error)?
    ) {
        Task { @MainActor in
            recordingError = error
            if let error { finish?.resume(throwing: error) }
            else { finish?.resume() }
            finish = nil
        }
    }

    private func stopSession() {
        timer?.invalidate()
        timer = nil
        if session.isRunning { session.stopRunning() }
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        onLevel?(0)
    }
}

enum MicrophoneError: LocalizedError {
    case noMicrophone
    case unavailable

    var errorDescription: String? {
        switch self {
        case .noMicrophone: "No microphone is available."
        case .unavailable: "The selected microphone is unavailable."
        }
    }
}
