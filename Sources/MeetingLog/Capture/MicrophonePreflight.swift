@preconcurrency import AVFoundation
import Foundation

@MainActor
final class MicrophonePreflight: NSObject, AVCaptureFileOutputRecordingDelegate {
    private let session = AVCaptureSession()
    private let dataOutput = AVCaptureAudioDataOutput()
    private let fileOutput = AVCaptureAudioFileOutput()
    private var timer: Timer?
    private var player: AVAudioPlayer?
    private var finish: CheckedContinuation<Void, Never>?
    var onLevel: ((Float) -> Void)?

    static var devices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
    }

    func start(deviceID: String?) throws {
        stop()
        guard let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .audio) else {
            throw PreflightError.noMicrophone
        }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(dataOutput), session.canAddOutput(fileOutput) else {
            session.commitConfiguration()
            throw PreflightError.unavailable
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

    func stop() {
        timer?.invalidate()
        timer = nil
        if fileOutput.isRecording { fileOutput.stopRecording() }
        if session.isRunning { session.stopRunning() }
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        onLevel?(0)
    }

    func recordAndPlayTest() async throws {
        guard session.isRunning else { throw PreflightError.unavailable }
        let url = FileManager.default.temporaryDirectory.appending(path: "meeting-log-mic-test.m4a")
        try? FileManager.default.removeItem(at: url)
        fileOutput.startRecording(to: url, outputFileType: .m4a, recordingDelegate: self)
        try await Task.sleep(for: .seconds(5))
        await withCheckedContinuation { continuation in
            finish = continuation
            fileOutput.stopRecording()
        }
        player = try AVAudioPlayer(contentsOf: url)
        player?.play()
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: (any Error)?
    ) {
        Task { @MainActor in
            finish?.resume()
            finish = nil
        }
    }
}

enum PreflightError: LocalizedError {
    case noMicrophone
    case unavailable
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .noMicrophone: "No microphone is available."
        case .unavailable: "The selected microphone cannot be tested."
        case .permissionDenied: "Microphone permission was denied."
        }
    }
}
