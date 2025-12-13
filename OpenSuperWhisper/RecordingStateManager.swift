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

    private init() {}

    // MARK: - State Transitions

    func startRecording() {
        guard state == .idle else { return }
        state = .recording
        recordingStartTime = Date()
        recordingDuration = 0
        startBlinking()
        startDurationTimer()

        AudioRecorder.shared.startRecording()
    }

    /// Stop recording and transition to decoding state.
    /// Returns the temporary recording URL if available.
    func stopRecording() -> URL? {
        guard state == .recording else { return nil }

        state = .decoding
        stopBlinking()
        stopDurationTimer()

        return AudioRecorder.shared.stopRecording()
    }

    /// Called after transcription completes.
    /// If copied is true, shows the "Copied" state briefly before hiding.
    func finishDecoding(copied: Bool) {
        if copied {
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
        AudioRecorder.shared.cancelRecording()
        state = .idle
    }

    /// Force reset to idle state.
    func reset() {
        stopBlinking()
        stopDurationTimer()
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
