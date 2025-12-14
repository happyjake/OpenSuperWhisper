import Foundation
import AVFoundation
import ScreenCaptureKit

/// Error types for system audio recording
enum SystemAudioError: LocalizedError {
    case unsupportedMacOSVersion
    case noDisplayFound
    case streamCreationFailed
    case permissionDenied
    case noAudioCaptured

    var errorDescription: String? {
        switch self {
        case .unsupportedMacOSVersion:
            return "System audio capture requires macOS 13.0 or later"
        case .noDisplayFound:
            return "No display found for audio capture"
        case .streamCreationFailed:
            return "Failed to create audio capture stream"
        case .permissionDenied:
            return "System audio capture permission denied. Please enable in System Settings > Privacy & Security > Screen Recording."
        case .noAudioCaptured:
            return "No audio was captured"
        }
    }
}

/// Records system audio using ScreenCaptureKit (macOS 13.0+)
/// This captures audio output from the system without interrupting playback.
@available(macOS 13.0, *)
class SystemAudioRecorder: NSObject, ObservableObject, SCStreamDelegate, SCStreamOutput {
    static let shared = SystemAudioRecorder()

    @Published var isRecording = false

    // ScreenCaptureKit objects
    private var stream: SCStream?

    // Audio capture state
    private var capturedSamples: [Float] = []
    private var captureSampleRate: Double = 48000.0
    private var captureChannels: UInt32 = 2
    private let captureQueue = DispatchQueue(label: "com.opensuperwhisper.system-audio-capture", qos: .userInitiated)
    private var currentRecordingURL: URL?
    private var sampleBufferCount: Int = 0

    // Target format for Whisper: 16kHz mono
    private let targetSampleRate: Double = 16000.0
    private let targetChannels: UInt32 = 1

    // Temporary directory for recordings
    private let temporaryDirectory: URL

    private override init() {
        let tempDir = FileManager.default.temporaryDirectory
        temporaryDirectory = tempDir.appendingPathComponent("temp_recordings")
        super.init()
        createTemporaryDirectoryIfNeeded()
    }

    private func createTemporaryDirectoryIfNeeded() {
        if !FileManager.default.fileExists(atPath: temporaryDirectory.path) {
            try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        }
    }

    // MARK: - Public Recording Interface

    func startRecording() throws {
        guard !isRecording else { return }

        print("SystemAudioRecorder: Starting recording with ScreenCaptureKit...")

        // Reset state
        capturedSamples = []
        sampleBufferCount = 0

        // Set up recording file path
        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = "\(timestamp).wav"
        currentRecordingURL = temporaryDirectory.appendingPathComponent(filename)

        // Start async setup
        Task {
            do {
                try await setupAndStartStream()
            } catch {
                print("SystemAudioRecorder: Failed to start - \(error)")
                await MainActor.run {
                    self.isRecording = false
                }
                // Post permission denied notification if it's a permission error
                if case SystemAudioError.permissionDenied = error {
                    NotificationCenter.default.post(name: .systemAudioPermissionDenied, object: nil)
                }
            }
        }
    }

    private func setupAndStartStream() async throws {
        // Get shareable content (requires Screen Recording permission)
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            print("SystemAudioRecorder: Failed to get shareable content - \(error)")
            throw SystemAudioError.permissionDenied
        }

        // Get the main display
        guard let display = content.displays.first else {
            print("SystemAudioRecorder: No display found")
            throw SystemAudioError.noDisplayFound
        }

        print("SystemAudioRecorder: Found display: \(display.width)x\(display.height)")

        // Create a filter that captures the entire display (but we only want audio)
        let filter = SCContentFilter(display: display, excludingWindows: [])

        // Configure stream for audio-only capture
        let config = SCStreamConfiguration()

        // Minimize video capture (we only want audio)
        config.width = 2  // Minimum size
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1 fps minimum
        config.queueDepth = 1

        // Enable audio capture
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true  // Don't capture our own app's audio

        print("SystemAudioRecorder: Creating stream with audio enabled")

        // Create the stream
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = stream

        // Add audio output
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)

        print("SystemAudioRecorder: Starting stream...")

        // Start the stream
        try await stream.startCapture()

        await MainActor.run {
            self.isRecording = true
            print("SystemAudioRecorder: Recording started successfully")
        }
    }

    func stopRecording() -> URL? {
        guard isRecording else { return nil }

        print("SystemAudioRecorder: Stopping recording... Sample buffers received: \(sampleBufferCount)")

        // Stop the stream
        Task {
            do {
                try await stream?.stopCapture()
            } catch {
                print("SystemAudioRecorder: Error stopping stream - \(error)")
            }
            stream = nil
        }

        isRecording = false

        // Get captured samples safely
        var samples: [Float] = []
        captureQueue.sync {
            samples = capturedSamples
        }

        print("SystemAudioRecorder: Captured \(samples.count) samples")

        guard !samples.isEmpty else {
            print("SystemAudioRecorder: No audio captured - likely permission denied or no audio playing")
            NotificationCenter.default.post(name: .systemAudioPermissionDenied, object: nil)
            return nil
        }

        // Recording succeeded - permission is granted
        NotificationCenter.default.post(name: .systemAudioPermissionGranted, object: nil)

        // Convert and save captured audio
        guard let outputURL = currentRecordingURL else { return nil }

        do {
            try convertAndSaveAudio(samples: samples, to: outputURL)
            print("SystemAudioRecorder: Audio saved to \(outputURL.path)")
            let url = currentRecordingURL
            currentRecordingURL = nil
            return url
        } catch {
            print("SystemAudioRecorder: Failed to save audio - \(error)")
            currentRecordingURL = nil
            return nil
        }
    }

    func cancelRecording() {
        guard isRecording else { return }

        Task {
            try? await stream?.stopCapture()
            stream = nil
        }

        isRecording = false
        capturedSamples = []

        // Delete temp file if exists
        if let url = currentRecordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        currentRecordingURL = nil
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }

        sampleBufferCount += 1

        // Extract audio samples from the buffer
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard status == noErr, let data = dataPointer else { return }

        // Get format description
        if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
            captureSampleRate = asbd.pointee.mSampleRate
            captureChannels = asbd.pointee.mChannelsPerFrame
        }

        // Convert to float samples (assuming float32 format from ScreenCaptureKit)
        let floatCount = length / MemoryLayout<Float>.size
        let floatPtr = UnsafeRawPointer(data).assumingMemoryBound(to: Float.self)
        let samples = Array(UnsafeBufferPointer(start: floatPtr, count: floatCount))

        captureQueue.async { [weak self] in
            self?.capturedSamples.append(contentsOf: samples)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("SystemAudioRecorder: Stream stopped with error - \(error)")
    }

    // MARK: - Audio Conversion

    private func convertAndSaveAudio(samples: [Float], to url: URL) throws {
        guard !samples.isEmpty else {
            throw SystemAudioError.noAudioCaptured
        }

        print("SystemAudioRecorder: Converting \(samples.count) samples, channels: \(captureChannels), rate: \(captureSampleRate)")

        // Convert stereo to mono if needed
        var monoSamples: [Float]
        if captureChannels == 2 {
            monoSamples = convertStereoToMono(samples)
        } else if captureChannels > 2 {
            monoSamples = convertMultiChannelToMono(samples, channels: Int(captureChannels))
        } else {
            monoSamples = samples
        }

        print("SystemAudioRecorder: After mono conversion: \(monoSamples.count) samples")

        // Resample from capture rate to target rate (16kHz)
        if captureSampleRate != targetSampleRate {
            monoSamples = resample(monoSamples, from: captureSampleRate, to: targetSampleRate)
            print("SystemAudioRecorder: After resampling: \(monoSamples.count) samples")
        }

        // Write WAV file
        try writeWAVFile(samples: monoSamples, sampleRate: targetSampleRate, to: url)
    }

    private func convertStereoToMono(_ stereoSamples: [Float]) -> [Float] {
        var monoSamples = [Float](repeating: 0, count: stereoSamples.count / 2)
        for i in 0..<monoSamples.count {
            let left = stereoSamples[i * 2]
            let right = stereoSamples[i * 2 + 1]
            monoSamples[i] = (left + right) / 2.0
        }
        return monoSamples
    }

    private func convertMultiChannelToMono(_ samples: [Float], channels: Int) -> [Float] {
        let frameCount = samples.count / channels
        var monoSamples = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            var sum: Float = 0
            for ch in 0..<channels {
                sum += samples[i * channels + ch]
            }
            monoSamples[i] = sum / Float(channels)
        }
        return monoSamples
    }

    private func resample(_ samples: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        let ratio = targetRate / sourceRate
        let outputCount = Int(Double(samples.count) * ratio)

        var outputSamples = [Float](repeating: 0, count: outputCount)

        for i in 0..<outputCount {
            let sourceIndex = Double(i) / ratio
            let lowerIndex = Int(sourceIndex)
            let upperIndex = min(lowerIndex + 1, samples.count - 1)
            let fraction = Float(sourceIndex - Double(lowerIndex))

            outputSamples[i] = samples[lowerIndex] * (1 - fraction) + samples[upperIndex] * fraction
        }

        return outputSamples
    }

    private func writeWAVFile(samples: [Float], sampleRate: Double, to url: URL) throws {
        // Convert float samples to 16-bit PCM
        var pcmSamples = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let clamped = max(-1.0, min(1.0, samples[i]))
            pcmSamples[i] = Int16(clamped * Float(Int16.max))
        }

        // Create WAV file
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(pcmSamples.count * MemoryLayout<Int16>.size)

        var fileData = Data()

        // RIFF header
        fileData.append(contentsOf: "RIFF".utf8)
        fileData.append(contentsOf: withUnsafeBytes(of: (36 + dataSize).littleEndian) { Array($0) })
        fileData.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        fileData.append(contentsOf: "fmt ".utf8)
        fileData.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        fileData.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        fileData.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
        fileData.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        fileData.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        fileData.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        fileData.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })

        // data chunk
        fileData.append(contentsOf: "data".utf8)
        fileData.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })

        // PCM data
        for sample in pcmSamples {
            var littleEndianSample = sample.littleEndian
            withUnsafeBytes(of: &littleEndianSample) { bytes in
                fileData.append(contentsOf: bytes)
            }
        }

        try fileData.write(to: url)
    }
}

// MARK: - Fallback for older macOS versions

class SystemAudioRecorderFallback {
    static func isAvailable() -> Bool {
        if #available(macOS 13.0, *) {
            return true
        }
        return false
    }
}
