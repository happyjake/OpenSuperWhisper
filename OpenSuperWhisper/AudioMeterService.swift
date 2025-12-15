//
//  AudioMeterService.swift
//  OpenSuperWhisper
//
//  Real-time audio amplitude metering for visualizing recording levels.
//

import Foundation
import AVFoundation
import Combine

/// Protocol for receiving RMS audio levels from SystemAudioRecorder
protocol SystemAudioMeterDelegate: AnyObject {
    func systemAudioRecorder(didUpdateRMS rms: Float, peak: Float)
}

/// Singleton service that provides real-time audio amplitude metering.
/// Supports both microphone (AVAudioRecorder) and system audio (ScreenCaptureKit) sources.
@MainActor
final class AudioMeterService: ObservableObject {
    static let shared = AudioMeterService()

    // MARK: - Published Properties

    /// Normalized amplitude value (0.0 to 1.0)
    @Published private(set) var normalizedAmplitude: Float = 0.0

    /// True when audio is clipping (peak ≥ 0.98 or > -1dB)
    @Published private(set) var isClipping: Bool = false

    /// Peak amplitude for peak hold indicator
    @Published private(set) var peakAmplitude: Float = 0.0

    // MARK: - Configuration Constants

    /// Minimum dBFS value (maps to 0.0)
    private let minDbFS: Float = -60.0

    /// Maximum dBFS value (maps to 1.0)
    private let maxDbFS: Float = -6.0

    /// dBFS threshold for clipping detection
    private let clippingThresholdDbFS: Float = -1.0

    /// Linear peak threshold for clipping detection
    private let clippingPeakThreshold: Float = 0.98

    /// Number of consecutive clipping frames before triggering
    private let clippingFrameCount: Int = 2

    /// EMA coefficient for attack (very fast rise - instant response to speech)
    private let attackCoefficient: Float = 0.55

    /// EMA coefficient for release (slow decay - calm falloff, not twitchy)
    private let releaseCoefficient: Float = 0.10

    /// Timer update frequency in Hz
    private let meterUpdateHz: Double = 60.0

    // MARK: - Too Quiet Detection

    /// Threshold below which audio is considered "too quiet"
    private let quietThreshold: Float = 0.05

    /// Duration of quiet before triggering isTooQuiet
    private let quietDuration: TimeInterval = 1.5

    /// Published state for too quiet hint
    @Published private(set) var isTooQuiet: Bool = false

    private var quietStartTime: Date?

    // MARK: - Internal State

    private var smoothedAmplitude: Float = 0.0
    private var clippingCounter: Int = 0
    private var meterTimer: Timer?
    private var isActive: Bool = false
    private weak var audioRecorder: AVAudioRecorder?

    // For clipping flash auto-reset
    private var clippingResetTask: Task<Void, Never>?

    private init() {}

    // MARK: - Microphone Metering

    /// Start metering for microphone recording via AVAudioRecorder.
    /// - Parameter recorder: The AVAudioRecorder instance (must have isMeteringEnabled = true)
    func startMicrophoneMetering(with recorder: AVAudioRecorder) {
        guard !isActive else { return }

        self.audioRecorder = recorder
        isActive = true
        smoothedAmplitude = 0.0
        clippingCounter = 0
        normalizedAmplitude = 0.0
        isClipping = false

        // Start timer at configured Hz for UI updates
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / meterUpdateHz, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateMicrophoneLevel()
            }
        }
    }

    private func updateMicrophoneLevel() {
        guard let recorder = audioRecorder, recorder.isRecording else {
            return
        }

        recorder.updateMeters()

        // AVAudioRecorder returns dBFS for channel 0
        let avgPower = recorder.averagePower(forChannel: 0)
        let peakPower = recorder.peakPower(forChannel: 0)

        processLevel(avgPowerDbFS: avgPower, peakPowerDbFS: peakPower)
    }

    // MARK: - System Audio Metering

    /// Start metering for system audio capture.
    /// Call this when starting system audio recording.
    func startSystemAudioMetering() {
        guard !isActive else { return }

        isActive = true
        smoothedAmplitude = 0.0
        clippingCounter = 0
        normalizedAmplitude = 0.0
        isClipping = false

        // System audio metering is callback-driven via SystemAudioMeterDelegate
        // No timer needed - we receive callbacks from SystemAudioRecorder
    }

    /// Process RMS and peak values from system audio capture.
    /// Called by SystemAudioRecorder via delegate pattern.
    func processSystemAudioLevel(rms: Float, peak: Float) {
        guard isActive else { return }

        // Convert linear RMS to dBFS
        let rmsDbFS = rms > 0 ? 20 * log10(rms) : -100.0
        let peakDbFS = peak > 0 ? 20 * log10(peak) : -100.0

        processLevel(avgPowerDbFS: rmsDbFS, peakPowerDbFS: peakDbFS, linearPeak: peak)
    }

    // MARK: - Level Processing

    private func processLevel(avgPowerDbFS: Float, peakPowerDbFS: Float, linearPeak: Float? = nil) {
        // 1. Normalize dBFS to 0...1 range
        let clampedDb = max(minDbFS, min(maxDbFS, avgPowerDbFS))
        let rawNormalized = (clampedDb - minDbFS) / (maxDbFS - minDbFS)

        // 2. Apply EMA smoothing (attack/release)
        let coefficient: Float
        if rawNormalized > smoothedAmplitude {
            // Rising (attack) - use fast coefficient
            coefficient = attackCoefficient
        } else {
            // Falling (release) - use slow coefficient
            coefficient = releaseCoefficient
        }

        smoothedAmplitude = coefficient * rawNormalized + (1 - coefficient) * smoothedAmplitude

        // 3. Update published value
        normalizedAmplitude = smoothedAmplitude

        // 4. Update peak amplitude
        if rawNormalized > peakAmplitude {
            peakAmplitude = rawNormalized
        } else {
            // Slow decay for peak hold
            peakAmplitude = max(0, peakAmplitude - 0.01)
        }

        // 5. Clipping detection
        let peakLinear = linearPeak ?? pow(10, peakPowerDbFS / 20)
        let isCurrentlyClipping = peakLinear >= clippingPeakThreshold || peakPowerDbFS > clippingThresholdDbFS

        if isCurrentlyClipping {
            clippingCounter += 1
        } else {
            clippingCounter = max(0, clippingCounter - 1)
        }

        // Trigger clipping if threshold exceeded
        if clippingCounter >= clippingFrameCount && !isClipping {
            triggerClipping()
        }

        // 6. Too quiet detection
        checkTooQuiet(rawNormalized)
    }

    private func checkTooQuiet(_ amplitude: Float) {
        if amplitude < quietThreshold {
            // Audio is quiet
            if quietStartTime == nil {
                quietStartTime = Date()
            } else if let startTime = quietStartTime,
                      Date().timeIntervalSince(startTime) >= quietDuration {
                // Been quiet long enough
                if !isTooQuiet {
                    isTooQuiet = true
                }
            }
        } else {
            // Audio is loud enough - reset
            quietStartTime = nil
            if isTooQuiet {
                isTooQuiet = false
            }
        }
    }

    private func triggerClipping() {
        isClipping = true

        // Cancel any existing reset task
        clippingResetTask?.cancel()

        // Auto-reset clipping after 200ms
        clippingResetTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.isClipping = false
            }
        }
    }

    // MARK: - Stop Metering

    /// Stop all metering activity.
    func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
        audioRecorder = nil
        clippingResetTask?.cancel()
        clippingResetTask = nil

        guard isActive else { return }
        isActive = false

        // Animate amplitude down to zero
        Task { @MainActor in
            await animateToZero()
        }
    }

    private func animateToZero() async {
        // Gradual decay over ~300ms (10 steps at 30ms each)
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 30_000_000) // 30ms
            smoothedAmplitude *= 0.7
            normalizedAmplitude = smoothedAmplitude

            if smoothedAmplitude < 0.01 {
                normalizedAmplitude = 0
                break
            }
        }

        normalizedAmplitude = 0
        peakAmplitude = 0
        isClipping = false
        clippingCounter = 0
        isTooQuiet = false
        quietStartTime = nil
    }

    /// Reset all state immediately without animation
    func reset() {
        meterTimer?.invalidate()
        meterTimer = nil
        audioRecorder = nil
        clippingResetTask?.cancel()
        clippingResetTask = nil
        isActive = false
        smoothedAmplitude = 0
        normalizedAmplitude = 0
        peakAmplitude = 0
        isClipping = false
        clippingCounter = 0
        isTooQuiet = false
        quietStartTime = nil
    }
}

// MARK: - SystemAudioMeterDelegate Conformance

extension AudioMeterService: SystemAudioMeterDelegate {
    nonisolated func systemAudioRecorder(didUpdateRMS rms: Float, peak: Float) {
        Task { @MainActor in
            self.processSystemAudioLevel(rms: rms, peak: peak)
        }
    }
}
