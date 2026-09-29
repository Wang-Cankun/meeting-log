@preconcurrency import AVFoundation
import Foundation

final class MicrophoneCapture: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "meeting-log.microphone", qos: .userInitiated)
    private let session = AVCaptureSession()
    private let dataOutput = AVCaptureAudioDataOutput()
    private let fileOutput = AVCaptureAudioFileOutput()
    private var timer: DispatchSourceTimer?
    private var finish: CheckedContinuation<Void, any Error>?
    private var recordingError: Error?
    private var previewGeneration = 0
    var onLevel: (@Sendable (Float) -> Void)?
    /// Raw dBFS (the louder of average and peak hold; nil without an audio channel) and uptime, every 100 ms.
    var onSignal: (@Sendable (Float?, UInt64) -> Void)?

    static var devices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    func setPreview(enabled: Bool, deviceID: String?, generation: Int) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard generation >= self.previewGeneration else {
                    continuation.resume()
                    return
                }
                self.previewGeneration = generation
                do {
                    if enabled {
                        try self.startOnQueue(deviceID: deviceID)
                    } else if !self.fileOutput.isRecording {
                        self.stopSessionOnQueue()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func startOnQueue(deviceID: String?) throws {
        if !fileOutput.isRecording { stopSessionOnQueue() }
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
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            let channel = self?.dataOutput.connection(with: .audio)?.audioChannels.first
            let raw = channel.map { max($0.averagePowerLevel, $0.peakHoldLevel) }
            let db = channel?.averagePowerLevel ?? -60
            self?.onLevel?(max(0, min(1, (db + 60) / 60)))
            self?.onSignal?(raw, DispatchTime.now().uptimeNanoseconds)
        }
        timer.resume()
        self.timer = timer
    }

    func startRecording(to outputURL: URL, deviceID: String?) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.startOnQueue(deviceID: deviceID)
                    if FileManager.default.fileExists(atPath: outputURL.path) {
                        try FileManager.default.removeItem(at: outputURL)
                    }
                    self.recordingError = nil
                    self.fileOutput.startRecording(to: outputURL, outputFileType: .m4a, recordingDelegate: self)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stopRecording() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                guard self.fileOutput.isRecording else {
                    let error = self.recordingError
                    self.recordingError = nil
                    self.stopSessionOnQueue()
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                    return
                }
                self.finish = continuation
                self.fileOutput.stopRecording()
            }
        }
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: (any Error)?
    ) {
        queue.async {
            self.recordingError = error
            self.stopSessionOnQueue()
            if let error { self.finish?.resume(throwing: error) }
            else { self.finish?.resume() }
            self.finish = nil
        }
    }

    private func stopSessionOnQueue() {
        timer?.cancel()
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
