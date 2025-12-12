//
//  ContentView.swift
//  OpenSuperWhisper
//
//  Created by user on 05.02.2025.
//

import AVFoundation
import Combine
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

@MainActor
class ContentViewModel: ObservableObject {
    private let stateManager = RecordingStateManager.shared
    @Published var recorder: AudioRecorder = .shared
    @Published var transcriptionService = TranscriptionService.shared
    @Published var recordingStore = RecordingStore.shared
    @Published var microphoneService = MicrophoneService.shared

    private var cancellables = Set<AnyCancellable>()

    // Forward state from shared manager
    var state: RecordingStateManager.State { stateManager.state }
    var isBlinking: Bool { stateManager.isBlinking }
    var recordingDuration: TimeInterval { stateManager.recordingDuration }
    var isRecording: Bool { stateManager.isRecording }

    init() {
        // Observe state changes to trigger view updates
        stateManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Observe recording store changes to trigger view updates
        recordingStore.objectWillChange
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
        // Use shared state manager to stop recording
        // Returns nil if already stopped by another UI (e.g., floating indicator)
        guard let tempURL = stateManager.stopRecording() else {
            return
        }

        let duration = stateManager.recordingDuration

        Task { [weak self] in
            guard let self = self else { return }

            do {
                print("start decoding...")
                let text = try await transcriptionService.transcribeAudio(url: tempURL, settings: Settings())

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
                try recorder.moveTemporaryRecording(from: tempURL, to: finalURL)

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
                // Hide the floating indicator after transcription completes
                IndicatorWindowManager.shared.hide()
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = ContentViewModel()
    @StateObject private var permissionsManager = PermissionsManager()
    @State private var isSettingsPresented = false
    @State private var searchText = ""
    @State private var showDeleteConfirmation = false

    private var filteredRecordings: [Recording] {
        if searchText.isEmpty {
            return viewModel.recordingStore.recordings
        } else {
            return viewModel.recordingStore.searchRecordings(query: searchText)
        }
    }

    var body: some View {
        VStack {
            if !permissionsManager.isMicrophonePermissionGranted {
                PermissionsView(permissionsManager: permissionsManager)
            } else {
                VStack(spacing: 0) {
                    // Search bar
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)

                        TextField("Search in transcriptions", text: $searchText)
                            .textFieldStyle(PlainTextFieldStyle())

                        if !searchText.isEmpty {
                            Button(action: {
                                searchText = ""
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                                    .imageScale(.medium)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(20)
                    .padding([.horizontal, .top])

                    ScrollViewReader { scrollProxy in
                        ScrollView(showsIndicators: false) {
                            if filteredRecordings.isEmpty {
                                VStack(spacing: 16) {
                                    if !searchText.isEmpty {
                                        // Show "no results" for search
                                        Image(systemName: "magnifyingglass")
                                            .font(.system(size: 40))
                                            .foregroundColor(.secondary)
                                            .padding(.top, 40)

                                        Text("No results found")
                                            .font(.headline)
                                            .foregroundColor(.secondary)

                                        Text("Try different search terms")
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                            .multilineTextAlignment(.center)
                                            .padding(.horizontal)
                                    } else {
                                        // Show "start recording" tip
                                        Image(systemName: "arrow.down.circle")
                                            .font(.system(size: 40))
                                            .foregroundColor(.secondary)
                                            .padding(.top, 40)

                                        Text("No recordings yet")
                                            .font(.headline)
                                            .foregroundColor(.secondary)

                                        Text("Tap the record button below to get started")
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                            .multilineTextAlignment(.center)
                                            .padding(.horizontal)

                                        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecord) {
                                            VStack(spacing: 8) {
                                                Text("Pro Tip:")
                                                    .font(.subheadline)
                                                    .foregroundColor(.secondary)

                                                HStack(spacing: 4) {
                                                    Text("Press")
                                                        .font(.subheadline)
                                                        .foregroundColor(.secondary)
                                                    Text(shortcut.description)
                                                        .font(.system(size: 16, weight: .medium))
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 3)
                                                        .background(Color.secondary.opacity(0.2))
                                                        .cornerRadius(6)
                                                    Text("anywhere")
                                                        .font(.subheadline)
                                                        .foregroundColor(.secondary)
                                                }

                                                Text("to quickly record and paste text")
                                                    .font(.subheadline)
                                                    .foregroundColor(.secondary)
                                            }
                                            .padding(.top, 16)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                            } else {
                                LazyVStack(spacing: 8) {
                                    ForEach(filteredRecordings) { recording in
                                        RecordingRow(recording: recording)
                                            .id(recording.id)
                                            .transition(.asymmetric(
                                                insertion: .scale.combined(with: .opacity),
                                                removal: .opacity.combined(with: .scale(scale: 0.8))
                                            ))
                                    }
                                }
                                .padding(.horizontal)
                                .padding(.top, 16)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: filteredRecordings)
                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: searchText)
                        .onChange(of: viewModel.recordingStore.recordings.count) { oldCount, newCount in
                            // Scroll to the newest recording when a new one is added
                            if newCount > oldCount, let newestRecording = viewModel.recordingStore.recordings.first {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    scrollProxy.scrollTo(newestRecording.id, anchor: .top)
                                }
                            }
                        }
                    }
                    .safeAreaInset(edge: .bottom) {
                        // Bottom bar with floating record button
                        VStack(spacing: 0) {
                            // Floating record button with liquid glass background
                            Button(action: {
                                if viewModel.isRecording {
                                    viewModel.startDecoding()
                                } else if viewModel.state == .idle {
                                    viewModel.startRecording()
                                }
                            }) {
                                switch viewModel.state {
                                case .decoding:
                                    ProgressView()
                                        .scaleEffect(1.0)
                                        .frame(width: 64, height: 64)
                                case .copied:
                                    CopiedButton()
                                default:
                                    MainRecordButton(isRecording: viewModel.isRecording)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.transcriptionService.isLoading || viewModel.state == .decoding || viewModel.state == .copied)
                            .background {
                                ZStack {
                                    // Soft outer glow - very blurred
                                    Circle()
                                        .fill(Color.white.opacity(0.6))
                                        .frame(width: 95, height: 95)
                                        .blur(radius: 15)

                                    // Glass body - soft gradient
                                    Circle()
                                        .fill(
                                            RadialGradient(
                                                colors: [
                                                    Color.white.opacity(0.95),
                                                    Color.white.opacity(0.85),
                                                    Color(white: 0.92).opacity(0.9)
                                                ],
                                                center: .topLeading,
                                                startRadius: 0,
                                                endRadius: 80
                                            )
                                        )
                                        .frame(width: 84, height: 84)
                                        .blur(radius: 0.5)
                                }
                                .shadow(color: .black.opacity(0.12), radius: 20, y: 10)
                            }
                            .padding(.bottom, 20)
                            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.isRecording)
                            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.state)

                            // Minimal bottom bar
                            HStack(alignment: .center) {
                                // Left: shortcut hint (minimal)
                                if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecord) {
                                    HStack(spacing: 4) {
                                        Text(shortcut.description)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        Text("mini recorder")
                                            .font(.caption2)
                                            .foregroundColor(.secondary.opacity(0.6))
                                    }
                                }

                                Spacer()

                                // Right: controls
                                HStack(spacing: 8) {
                                    MicrophonePickerIconView(microphoneService: viewModel.microphoneService)

                                    if !viewModel.recordingStore.recordings.isEmpty {
                                        Button(action: {
                                            showDeleteConfirmation = true
                                        }) {
                                            Image(systemName: "trash")
                                                .font(.system(size: 14))
                                                .foregroundColor(.secondary)
                                                .frame(width: 28, height: 28)
                                                .background(Color(NSColor.controlBackgroundColor))
                                                .cornerRadius(6)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Delete all recordings")
                                        .confirmationDialog(
                                            "Delete All Recordings",
                                            isPresented: $showDeleteConfirmation,
                                            titleVisibility: .visible
                                        ) {
                                            Button("Delete All", role: .destructive) {
                                                viewModel.recordingStore.deleteAllRecordings()
                                            }
                                            Button("Cancel", role: .cancel) {}
                                        } message: {
                                            Text("Are you sure you want to delete all recordings? This action cannot be undone.")
                                        }
                                        .interactiveDismissDisabled()
                                    }

                                    Button(action: {
                                        isSettingsPresented.toggle()
                                    }) {
                                        Image(systemName: "gear")
                                            .font(.system(size: 14))
                                            .foregroundColor(.secondary)
                                            .frame(width: 28, height: 28)
                                            .background(Color(NSColor.controlBackgroundColor))
                                            .cornerRadius(6)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Settings")
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.regularMaterial)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 400, idealWidth: 400)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay {
            let isPermissionsGranted = permissionsManager.isMicrophonePermissionGranted
                && permissionsManager.isAccessibilityPermissionGranted

            if viewModel.transcriptionService.isLoading && isPermissionsGranted {
                ZStack {
                    Color.black.opacity(0.3)
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Loading Whisper Model...")
                            .foregroundColor(.white)
                            .font(.headline)
                    }
                }
                .ignoresSafeArea()
            }
        }
        .fileDropHandler()
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView()
        }
    }
}

struct PermissionsView: View {
    @ObservedObject var permissionsManager: PermissionsManager

    var body: some View {
        VStack(spacing: 20) {
            Text("Required Permissions")
                .font(.title)
                .padding()

            PermissionRow(
                isGranted: permissionsManager.isMicrophonePermissionGranted,
                title: "Microphone Access",
                description: "Required for audio recording",
                action: {
                    permissionsManager.requestMicrophonePermissionOrOpenSystemPreferences()
                }
            )

            Spacer()
        }
        .padding()
    }
}

struct PermissionRow: View {
    let isGranted: Bool
    let title: String
    let description: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(isGranted ? .green : .red)

                Text(title)
                    .font(.headline)

                Spacer()

                if !isGranted {
                    Button("Grant Access") {
                        action()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Text(description)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(10)
    }
}

struct RecordingRow: View {
    let recording: Recording
    @StateObject private var audioRecorder = AudioRecorder.shared
    @StateObject private var recordingStore = RecordingStore.shared
    @State private var isHovered = false
    @State private var isExpanded = false
    @State private var showFullText = false
    @State private var showCopyConfirmation = false

    private var isPlaying: Bool {
        audioRecorder.isPlaying && audioRecorder.currentlyPlayingURL == recording.url
    }

    private var wordCount: Int {
        recording.transcription.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    private var formattedDuration: String {
        let minutes = Int(recording.duration) / 60
        let seconds = Int(recording.duration) % 60
        return "\(minutes):\(String(format: "%02d", seconds))"
    }

    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: recording.timestamp)
    }

    private var trimmedText: String {
        recording.transcription.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Transcription Area
            VStack(alignment: .leading, spacing: 8) {
                Text(trimmedText)
                    .font(.body)
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(isExpanded ? nil : 4)

                // Read more / Read less button
                if trimmedText.count > 150 {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Text(isExpanded ? "Read less" : "Read more")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            // Bottom Bar - Metadata + Actions
            HStack(spacing: 0) {
                // Left: Metadata
                HStack(spacing: 6) {
                    Text(formattedTime)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Text("•")
                        .font(.subheadline)
                        .foregroundColor(.secondary.opacity(0.5))

                    Text(formattedDuration)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Text("•")
                        .font(.subheadline)
                        .foregroundColor(.secondary.opacity(0.5))

                    Text("\(wordCount) words")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Right: Action Buttons
                HStack(spacing: 16) {
                    // Play/Stop Button
                    Button(action: togglePlayback) {
                        Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(isPlaying ? .red : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isPlaying ? "Stop" : "Play")

                    // Copy Button
                    Button(action: copyToClipboard) {
                        Image(systemName: showCopyConfirmation ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(showCopyConfirmation ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy to clipboard")

                    // Delete Button
                    Button(action: deleteRecording) {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        .contentShape(Rectangle())
        .onTapGesture {
            showFullText = true
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .sheet(isPresented: $showFullText) {
            TranscriptionDetailView(recording: recording)
        }
    }

    // MARK: - Actions

    private func togglePlayback() {
        if isPlaying {
            audioRecorder.stopPlaying()
        } else {
            audioRecorder.playRecording(url: recording.url)
        }
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recording.transcription, forType: .string)

        withAnimation(.easeInOut(duration: 0.2)) {
            showCopyConfirmation = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.2)) {
                showCopyConfirmation = false
            }
        }
    }

    private func deleteRecording() {
        if isPlaying {
            audioRecorder.stopPlaying()
        }
        withAnimation(.easeInOut(duration: 0.3)) {
            recordingStore.deleteRecording(recording)
        }
    }
}

// MARK: - Full Transcription Detail View (Sheet)
struct TranscriptionDetailView: View {
    let recording: Recording
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recordingStore = RecordingStore.shared
    @State private var editableText: String = ""
    @State private var displayText: String = ""  // Track displayed text separately
    @State private var isEditing = false
    @State private var showCopyConfirmation = false
    @FocusState private var isTextFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcription")
                        .font(.headline)
                    Text(recording.timestamp, format: .dateTime.month().day().year().hour().minute())
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    // Copy button
                    Button(action: copyToClipboard) {
                        Image(systemName: showCopyConfirmation ? "checkmark.circle.fill" : "doc.on.doc")
                            .foregroundColor(showCopyConfirmation ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy to clipboard")

                    // Edit/Done button
                    if isEditing {
                        Button("Done") {
                            saveChanges()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else {
                        Button("Edit") {
                            editableText = displayText
                            isEditing = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                isTextFocused = true
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    // Close button
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()

            Divider()

            // Content
            ScrollView {
                if isEditing {
                    TextEditor(text: $editableText)
                        .font(.body)
                        .focused($isTextFocused)
                        .frame(maxWidth: .infinity, minHeight: 300)
                        .padding()
                        .onKeyPress(.escape) {
                            isEditing = false
                            return .handled
                        }
                } else {
                    Text(displayText)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding()
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            displayText = recording.transcription
        }
    }

    private func copyToClipboard() {
        let textToCopy = isEditing ? editableText : displayText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textToCopy, forType: .string)

        withAnimation {
            showCopyConfirmation = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation {
                showCopyConfirmation = false
            }
        }
    }

    private func saveChanges() {
        guard editableText != displayText else {
            isEditing = false
            return
        }

        var updatedRecording = recording
        updatedRecording.transcription = editableText
        recordingStore.updateRecording(updatedRecording)

        // Update local display text and return to read-only mode (don't dismiss)
        displayText = editableText
        isEditing = false
    }
}

struct MicrophonePickerIconView: View {
    @ObservedObject var microphoneService: MicrophoneService
    @State private var showMenu = false
    
    private var builtInMicrophones: [MicrophoneService.AudioDevice] {
        microphoneService.availableMicrophones.filter { $0.isBuiltIn }
    }
    
    private var externalMicrophones: [MicrophoneService.AudioDevice] {
        microphoneService.availableMicrophones.filter { !$0.isBuiltIn }
    }
    
    var body: some View {
        Button(action: {
            showMenu.toggle()
        }) {
            Image(systemName: microphoneService.availableMicrophones.isEmpty ? "mic.slash" : "mic.fill")
                .font(.title3)
                .foregroundColor(.secondary)
                .frame(width: 32, height: 32)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .help(microphoneService.currentMicrophone?.displayName ?? "Select microphone")
        .popover(isPresented: $showMenu, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 0) {
                if microphoneService.availableMicrophones.isEmpty {
                    Text("No microphones available")
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    ForEach(builtInMicrophones) { microphone in
                        Button(action: {
                            microphoneService.selectMicrophone(microphone)
                            showMenu = false
                        }) {
                            HStack {
                                Text(microphone.displayName)
                                Spacer()
                                if let current = microphoneService.currentMicrophone,
                                   current.id == microphone.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    
                    if !builtInMicrophones.isEmpty && !externalMicrophones.isEmpty {
                        Divider()
                            .padding(.vertical, 4)
                    }
                    
                    ForEach(externalMicrophones) { microphone in
                        Button(action: {
                            microphoneService.selectMicrophone(microphone)
                            showMenu = false
                        }) {
                            HStack {
                                Text(microphone.displayName)
                                Spacer()
                                if let current = microphoneService.currentMicrophone,
                                   current.id == microphone.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minWidth: 200)
            .padding(.vertical, 8)
        }
    }
}

struct MainRecordButton: View {
    let isRecording: Bool

    var body: some View {
        ZStack {
            // Background circle
            Circle()
                .fill(isRecording ? Color.red : Color.red.opacity(0.12))
                .frame(width: 64, height: 64)

            // Pulsing ring when recording
            if isRecording {
                Circle()
                    .stroke(Color.red.opacity(0.5), lineWidth: 3)
                    .frame(width: 64, height: 64)
                    .scaleEffect(isRecording ? 1.3 : 1.0)
                    .opacity(isRecording ? 0 : 1)
                    .animation(
                        .easeOut(duration: 1.0).repeatForever(autoreverses: false),
                        value: isRecording
                    )
            } else {
                // Outer ring for idle state
                Circle()
                    .stroke(Color.red.opacity(0.3), lineWidth: 2)
                    .frame(width: 64, height: 64)
            }

            // Mic icon - always visible, with recording indicator
            ZStack {
                Image(systemName: "mic.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(isRecording ? .white : .red)

                // Small recording dot indicator
                if isRecording {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 8, height: 8)
                        .offset(x: 12, y: -12)
                        .opacity(isRecording ? 1 : 0)
                }
            }
        }
        .shadow(color: isRecording ? .red.opacity(0.5) : .black.opacity(0.1), radius: isRecording ? 12 : 4)
        .scaleEffect(isRecording ? 1.08 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isRecording)
    }
}

struct CopiedButton: View {
    var body: some View {
        ZStack {
            // Solid background to block glass effect - matches glass body size
            Circle()
                .fill(Color.green)
                .frame(width: 84, height: 84)

            // Inner circle with gradient for depth
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.green.opacity(0.9), Color.green],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 64, height: 64)

            // Checkmark icon
            Image(systemName: "checkmark")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white)
        }
        .shadow(color: .green.opacity(0.5), radius: 12)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
