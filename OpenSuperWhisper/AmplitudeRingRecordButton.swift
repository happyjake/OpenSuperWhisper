//
//  AmplitudeRingRecordButton.swift
//  OpenSuperWhisper
//
//  A radial amplitude ring visualization around the record button.
//  Provides real-time visual feedback of audio input level.
//

import SwiftUI

// MARK: - Configuration

/// Configuration constants for the amplitude ring visualization
struct AmplitudeRingConfig {
    // Geometry
    static let buttonRadius: CGFloat = 32
    static let baselineOffset: CGFloat = 6
    static let maxExpandPx: CGFloat = 14
    static let baseThickness: CGFloat = 2.5
    static let maxThickness: CGFloat = 6.0

    // Colors
    static let idleColor = Color.red.opacity(0.3)
    static let armedColor = Color.red.opacity(0.5)
    static let recordingColor = Color.red
    static let clippingColor = Color.orange
    static let glowColor = Color.red

    // Animation
    static let smoothingAlphaAttack: CGFloat = 0.25
    static let smoothingAlphaRelease: CGFloat = 0.08
    static let clippingFlashDuration: TimeInterval = 0.2
    static let armedPulseDuration: TimeInterval = 0.8

    // Glow
    static let glowRadius: CGFloat = 6
    static let maxGlowOpacity: CGFloat = 0.3
}

// MARK: - AmplitudeRingRecordButton

/// A record button wrapped with an amplitude-reactive ring visualization.
/// Shows different visual states: idle, armed, recording, clipping, and processing.
struct AmplitudeRingRecordButton: View {
    let state: RecordingStateManager.State
    let isArmed: Bool

    @StateObject private var meterService = AudioMeterService.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(state: RecordingStateManager.State, isArmed: Bool = false) {
        self.state = state
        self.isArmed = isArmed
    }

    var body: some View {
        ZStack {
            // Amplitude ring (behind the button)
            if reduceMotion {
                SimplifiedAmplitudeRing(
                    amplitude: meterService.normalizedAmplitude,
                    isArmed: isArmed,
                    isRecording: state == .recording,
                    isProcessing: state == .decoding
                )
            } else {
                AmplitudeRingCanvas(
                    amplitude: meterService.normalizedAmplitude,
                    isClipping: meterService.isClipping,
                    isArmed: isArmed,
                    isRecording: state == .recording,
                    isProcessing: state == .decoding
                )
            }

            // Existing button (unchanged)
            MainRecordButton(isRecording: state == .recording)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }

    // MARK: - Accessibility

    private var accessibilityLabel: String {
        var label: String
        switch state {
        case .idle:
            label = isArmed ? "Recording armed" : "Record button"
        case .recording:
            let amplitudePercent = Int(meterService.normalizedAmplitude * 100)
            label = "Recording. Audio level: \(amplitudePercent) percent"
        case .decoding:
            label = "Processing transcription"
        case .copied:
            label = "Text copied"
        }

        if meterService.isClipping && state == .recording {
            label += ". Warning: Audio clipping detected"
        }

        return label
    }

    private var accessibilityHint: String {
        switch state {
        case .idle:
            return "Press to start recording"
        case .recording:
            return "Press to stop recording"
        case .decoding:
            return "Please wait"
        case .copied:
            return "Recording complete"
        }
    }
}

// MARK: - AmplitudeRingCanvas

/// Canvas-based amplitude ring visualization for smooth 60fps rendering.
struct AmplitudeRingCanvas: View {
    let amplitude: Float
    let isClipping: Bool
    let isArmed: Bool
    let isRecording: Bool
    let isProcessing: Bool

    @State private var smoothedAmplitude: CGFloat = 0
    @State private var frozenAmplitude: CGFloat = 0
    @State private var showClippingFlash = false
    @State private var armedPulse: CGFloat = 0

    private let config = AmplitudeRingConfig.self

    // Frame needs to be large enough for ring + expansion + glow
    private let frameSize: CGFloat = 120

    var body: some View {
        ZStack {
            // Glow layer (using SwiftUI shadow for smooth circular glow)
            if isArmed || (isRecording && !isProcessing) {
                Circle()
                    .stroke(config.glowColor, lineWidth: currentThickness)
                    .frame(width: currentDiameter, height: currentDiameter)
                    .blur(radius: config.glowRadius)
                    .opacity(glowOpacity)
            }

            // Ring layer (using Canvas for precise control)
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let displayAmp = isProcessing ? frozenAmplitude : smoothedAmplitude

                // Calculate ring geometry
                let radius = config.buttonRadius + config.baselineOffset + (displayAmp * config.maxExpandPx)
                let thickness = config.baseThickness + (displayAmp * (config.maxThickness - config.baseThickness))

                // Draw ring
                let ringRect = CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                let ringPath = Circle().path(in: ringRect)

                context.stroke(
                    ringPath,
                    with: .color(ringColor.opacity(ringOpacity)),
                    style: StrokeStyle(lineWidth: thickness, lineCap: .round)
                )
            }
        }
        .frame(width: frameSize, height: frameSize)
        .onChange(of: amplitude) { _, newValue in
            updateSmoothedAmplitude(newValue)
        }
        .onChange(of: isClipping) { _, clipping in
            if clipping {
                triggerClippingFlash()
            }
        }
        .onChange(of: isProcessing) { _, processing in
            if processing {
                frozenAmplitude = smoothedAmplitude
            }
        }
        .onChange(of: isArmed) { _, armed in
            updateArmedPulse(armed)
        }
        .onAppear {
            if isArmed {
                updateArmedPulse(true)
            }
        }
    }

    // MARK: - Computed Properties for Glow

    private var displayAmplitude: CGFloat {
        isProcessing ? frozenAmplitude : smoothedAmplitude
    }

    private var currentDiameter: CGFloat {
        (config.buttonRadius + config.baselineOffset + (displayAmplitude * config.maxExpandPx)) * 2
    }

    private var currentThickness: CGFloat {
        config.baseThickness + (displayAmplitude * (config.maxThickness - config.baseThickness))
    }

    private var glowOpacity: Double {
        if isArmed {
            return 0.2 + 0.15 * armedPulse
        } else if isRecording && !isProcessing {
            return Double(config.maxGlowOpacity * displayAmplitude)
        }
        return 0
    }

    // MARK: - Drawing

    private var ringColor: Color {
        if showClippingFlash {
            return config.clippingColor
        } else if isArmed {
            return config.armedColor
        } else if isRecording || isProcessing {
            return config.recordingColor
        } else {
            return config.idleColor
        }
    }

    private var ringOpacity: Double {
        if showClippingFlash {
            return 1.0
        } else if isArmed {
            return 0.5 + 0.2 * armedPulse
        } else if isRecording {
            return 0.7 + 0.3 * Double(smoothedAmplitude)
        } else if isProcessing {
            return 0.6
        } else {
            return 0.3
        }
    }

    // MARK: - Animation Updates

    private func updateSmoothedAmplitude(_ newValue: Float) {
        let alpha: CGFloat
        if CGFloat(newValue) > smoothedAmplitude {
            // Attack - fast rise
            alpha = config.smoothingAlphaAttack
        } else {
            // Release - slow decay
            alpha = config.smoothingAlphaRelease
        }
        smoothedAmplitude = alpha * CGFloat(newValue) + (1 - alpha) * smoothedAmplitude
    }

    private func triggerClippingFlash() {
        showClippingFlash = true

        Task {
            try? await Task.sleep(nanoseconds: UInt64(config.clippingFlashDuration * 1_000_000_000))
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.1)) {
                    showClippingFlash = false
                }
            }
        }
    }

    private func updateArmedPulse(_ armed: Bool) {
        if armed {
            withAnimation(.easeInOut(duration: config.armedPulseDuration).repeatForever(autoreverses: true)) {
                armedPulse = 1.0
            }
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                armedPulse = 0
            }
        }
    }
}

// MARK: - SimplifiedAmplitudeRing (Reduce Motion)

/// Simplified ring for users with Reduce Motion accessibility setting.
/// Shows state through color changes instead of animations.
struct SimplifiedAmplitudeRing: View {
    let amplitude: Float
    let isArmed: Bool
    let isRecording: Bool
    let isProcessing: Bool

    private let config = AmplitudeRingConfig.self

    var body: some View {
        ZStack {
            // Background ring
            Circle()
                .stroke(ringColor, lineWidth: config.baseThickness)
                .frame(width: ringSize, height: ringSize)

            // Amplitude fill indicator (arc from top)
            if isRecording && !isProcessing {
                Circle()
                    .trim(from: 0, to: CGFloat(amplitude))
                    .stroke(config.recordingColor, lineWidth: config.baseThickness + 1)
                    .frame(width: ringSize, height: ringSize)
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: 96, height: 96)
    }

    private var ringSize: CGFloat {
        (config.buttonRadius + config.baselineOffset) * 2
    }

    private var ringColor: Color {
        if isArmed {
            return config.armedColor
        } else if isRecording || isProcessing {
            return config.recordingColor.opacity(0.5)
        } else {
            return config.idleColor
        }
    }
}

// MARK: - MiniAmplitudeBar

/// A small vertical amplitude bar for use in compact UIs (like IndicatorWindow).
struct MiniAmplitudeBar: View {
    let level: Float
    let isClipping: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                // Background
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.3))

                // Level fill
                RoundedRectangle(cornerRadius: 2)
                    .fill(isClipping ? Color.orange : Color.green)
                    .frame(height: geometry.size.height * CGFloat(level))
            }
        }
        .frame(width: 4, height: 16)
        .animation(.linear(duration: 0.05), value: level)
    }
}

// MARK: - Preview

#Preview("Amplitude Ring States") {
    VStack(spacing: 40) {
        HStack(spacing: 30) {
            VStack {
                AmplitudeRingRecordButton(state: .idle)
                Text("Idle").font(.caption)
            }

            VStack {
                AmplitudeRingRecordButton(state: .idle, isArmed: true)
                Text("Armed").font(.caption)
            }

            VStack {
                AmplitudeRingRecordButton(state: .recording)
                Text("Recording").font(.caption)
            }

            VStack {
                AmplitudeRingRecordButton(state: .decoding)
                Text("Processing").font(.caption)
            }
        }

        HStack(spacing: 20) {
            ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { amp in
                VStack {
                    MiniAmplitudeBar(level: Float(amp), isClipping: amp >= 0.95)
                        .frame(height: 32)
                    Text("\(Int(amp * 100))%")
                        .font(.caption2)
                }
            }
        }
    }
    .padding(40)
}
