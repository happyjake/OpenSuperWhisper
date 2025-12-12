import Cocoa
import SwiftUI
import Combine

@MainActor
protocol IndicatorViewDelegate: AnyObject {
    func didFinishDecoding()
}

@MainActor
class IndicatorViewModel: ObservableObject {
    @Published var isVisible = false

    private let stateManager = RecordingStateManager.shared
    private let recordingStore = RecordingStore.shared
    private var cancellables = Set<AnyCancellable>()

    var delegate: IndicatorViewDelegate?

    // Forward state from shared manager
    var state: RecordingStateManager.State { stateManager.state }
    var isBlinking: Bool { stateManager.isBlinking }
    var recordingDuration: TimeInterval { stateManager.recordingDuration }

    init() {
        // Observe state changes to trigger view updates
        stateManager.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        stateManager.$isBlinking
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    func startRecording() {
        stateManager.startRecording()
    }

    func startDecoding() {
        guard let tempURL = stateManager.stopRecording() else {
            print("!!! Not found record url !!!")
            delegate?.didFinishDecoding()
            return
        }

        let transcription = TranscriptionService.shared
        let duration = stateManager.recordingDuration

        Task { [weak self] in
            guard let self = self else { return }

            do {
                print("start decoding...")
                let text = try await transcription.transcribeAudio(url: tempURL, settings: Settings())

                // Create a new Recording instance
                let timestamp = Date()
                let fileName = "\(Int(timestamp.timeIntervalSince1970)).wav"
                let finalURL = Recording(
                    id: UUID(),
                    timestamp: timestamp,
                    fileName: fileName,
                    transcription: text,
                    duration: duration
                ).url

                // Move the temporary recording to final location
                try AudioRecorder.shared.moveTemporaryRecording(from: tempURL, to: finalURL)

                // Save the recording to store
                await MainActor.run {
                    self.recordingStore.addRecording(Recording(
                        id: UUID(),
                        timestamp: timestamp,
                        fileName: fileName,
                        transcription: text,
                        duration: duration
                    ))
                }

                // Copy transcribed text to clipboard if enabled
                let shouldCopy = AppPreferences.shared.autoCopyToClipboard
                if shouldCopy {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    print("Transcription result (copied to clipboard): \(text)")
                } else {
                    print("Transcription result: \(text)")
                }

                // Transition to copied state or idle
                await MainActor.run {
                    self.stateManager.finishDecoding(copied: shouldCopy)
                }

                // Wait for copied state to show before hiding
                if shouldCopy {
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                }

            } catch {
                print("Error transcribing audio: \(error)")
                try? FileManager.default.removeItem(at: tempURL)
                await MainActor.run {
                    self.stateManager.reset()
                }
            }

            await MainActor.run {
                self.delegate?.didFinishDecoding()
            }
        }
    }

    func cancelRecording() {
        stateManager.cancel()
    }

    @MainActor
    func hideWithAnimation() async {
        await withCheckedContinuation { continuation in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                self.isVisible = false
            } completion: {
                continuation.resume()
            }
        }
    }
}

struct RecordingIndicator: View {
    let isBlinking: Bool

    var body: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.red.opacity(0.8),
                        Color.red
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 8, height: 8)
            .shadow(color: .red.opacity(0.5), radius: 4)
            .opacity(isBlinking ? 0.3 : 1.0)
            .animation(.easeInOut(duration: 0.4), value: isBlinking)
    }
}

struct IndicatorWindow: View {
    @ObservedObject var viewModel: IndicatorViewModel
    @Environment(\.colorScheme) private var colorScheme

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.24)
            : Color.white.opacity(0.24)
    }

    var body: some View {
        let rect = RoundedRectangle(cornerRadius: 24)

        VStack(spacing: 12) {
            switch viewModel.state {
            case .recording:
                HStack(spacing: 8) {
                    RecordingIndicator(isBlinking: viewModel.isBlinking)
                        .frame(width: 24)

                    Text("Recording...")
                        .font(.system(size: 13, weight: .semibold))

                    Spacer()

                    // Stop button with fixed alignment
                    Button(action: {
                        IndicatorWindowManager.shared.stopRecording()
                    }) {
                        ZStack {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 20, height: 20)
                            Image(systemName: "stop.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .buttonStyle(.plain)
                    .contentShape(Circle())
                }

            case .decoding:
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 24)

                    Text("Transcribing...")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .copied:
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 16))
                        .frame(width: 24)

                    Text("Copied!")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background {
            rect
                .fill(backgroundColor)
                .background {
                    rect
                        .fill(Material.thinMaterial)
                }
                .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 4)
        }
        .clipShape(rect)
        .frame(width: 200)
        .scaleEffect(viewModel.isVisible ? 1 : 0.5)
        .offset(y: viewModel.isVisible ? 0 : 20)
        .opacity(viewModel.isVisible ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.isVisible)
        .onAppear {
            viewModel.isVisible = true
        }
    }
}

struct IndicatorWindowPreview: View {
    @StateObject private var recordingVM = IndicatorViewModel()

    var body: some View {
        VStack(spacing: 20) {
            IndicatorWindow(viewModel: recordingVM)
        }
        .padding()
        .frame(height: 200)
        .background(Color(.windowBackgroundColor))
    }
}

#Preview {
    IndicatorWindowPreview()
}
