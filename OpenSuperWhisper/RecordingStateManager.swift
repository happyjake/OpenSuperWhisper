import Foundation
import SwiftUI
import Combine

/// Single source of truth for recording state.
/// Both ContentView and IndicatorWindow observe this shared manager.
@MainActor
class RecordingStateManager: ObservableObject {
    static let shared = RecordingStateManager()

    enum State: Equatable {
        case idle
        case recording
        case decoding
        case copied
        case pasted
    }

    @Published var state: State = .idle
    @Published var isBlinking = false
    @Published var recordingDuration: TimeInterval = 0

    private var blinkTimer: Timer?
    private var durationTimer: Timer?
    private var recordingStartTime: Date?

    var isRecording: Bool { state == .recording }
    var isDecoding: Bool { state == .decoding }
    var isCopied: Bool { state == .copied }
    var isPasted: Bool { state == .pasted }

    private init() {}

    // MARK: - State Transitions

    func startRecording() {
        guard state == .idle else { return }
        state = .recording
        recordingStartTime = Date()
        recordingDuration = 0
        startBlinking()
        startDurationTimer()

        // Route to appropriate recorder based on selected source
        if let device = MicrophoneService.shared.getActiveMicrophone(),
           device.isSystemAudio {
            if #available(macOS 13.0, *) {
                do {
                    // Set up metering delegate before starting
                    SystemAudioRecorder.shared.meterDelegate = AudioMeterService.shared
                    try SystemAudioRecorder.shared.startRecording()
                    // Start metering after recording starts
                    AudioMeterService.shared.startSystemAudioMetering()
                } catch {
                    print("Failed to start system audio recording: \(error)")
                    reset()
                    NotificationCenter.default.post(
                        name: .systemAudioRecordingFailed,
                        object: nil,
                        userInfo: ["error": error]
                    )
                }
            }
        } else {
            // Microphone metering is started automatically by AudioRecorder
            AudioRecorder.shared.startRecording()
        }
    }

    /// Stop recording and transition to decoding state.
    /// Returns the temporary recording URL if available.
    func stopRecording() -> URL? {
        guard state == .recording else { return nil }

        state = .decoding
        stopBlinking()
        stopDurationTimer()

        // Stop metering
        AudioMeterService.shared.stopMetering()

        // Route to appropriate recorder based on selected source
        if let device = MicrophoneService.shared.getActiveMicrophone(),
           device.isSystemAudio {
            if #available(macOS 13.0, *) {
                return SystemAudioRecorder.shared.stopRecording()
            }
            return nil
        } else {
            return AudioRecorder.shared.stopRecording()
        }
    }

    /// Called after transcription completes.
    /// Shows the appropriate state (copied/pasted) briefly before hiding.
    func finishDecoding(copied: Bool, pasted: Bool = false) {
        if pasted {
            state = .pasted
            // Auto-transition to idle after 1 second
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                await MainActor.run {
                    if self.state == .pasted {
                        self.state = .idle
                    }
                }
            }
        } else if copied {
            state = .copied
            // Auto-transition to idle after 1 second
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                await MainActor.run {
                    if self.state == .copied {
                        self.state = .idle
                    }
                }
            }
        } else {
            state = .idle
        }
    }

    /// Cancel recording without transcribing.
    func cancel() {
        stopBlinking()
        stopDurationTimer()

        // Stop metering
        AudioMeterService.shared.stopMetering()

        // Route cancel to appropriate recorder
        if let device = MicrophoneService.shared.getActiveMicrophone(),
           device.isSystemAudio {
            if #available(macOS 13.0, *) {
                SystemAudioRecorder.shared.cancelRecording()
            }
        } else {
            AudioRecorder.shared.cancelRecording()
        }

        state = .idle
    }

    /// Force reset to idle state.
    func reset() {
        stopBlinking()
        stopDurationTimer()

        // Stop metering
        AudioMeterService.shared.stopMetering()

        state = .idle
        recordingDuration = 0
    }

    // MARK: - Blinking Animation

    private func startBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.isBlinking.toggle()
            }
        }
    }

    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        isBlinking = false
    }

    // MARK: - Duration Timer

    private func startDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let startTime = self.recordingStartTime else { return }
                self.recordingDuration = Date().timeIntervalSince(startTime)
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }
}
