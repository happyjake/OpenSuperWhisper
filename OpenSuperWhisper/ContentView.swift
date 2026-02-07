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

extension Notification.Name {
    static let modelLoadErrorOccurred = Notification.Name("modelLoadErrorOccurred")
}

@MainActor
class ContentViewModel: ObservableObject {
    private let stateManager = RecordingStateManager.shared
    @Published var recorder: AudioRecorder = .shared
    @Published var transcriptionService = TranscriptionService.shared
    @Published var recordingStore = RecordingStore.shared
    @Published var microphoneService = MicrophoneService.shared
    @Published var permissionsManager = PermissionsManager()

    // Model error handling
    @Published var showModelError = false
    @Published var modelErrorMessage = ""

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

        // Observe model load errors from any source (e.g., floating indicator)
        NotificationCenter.default.publisher(for: .modelLoadErrorOccurred)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                if let message = notification.userInfo?["message"] as? String {
                    self?.modelErrorMessage = message
                    self?.showModelError = true
                }
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
            // If we transitioned to .decoding but got no URL, recording was too short
            // Reset to idle so user can try again
            if stateManager.state == .decoding {
                stateManager.reset()
            }
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

                // Handle clipboard/paste based on user preferences
                let outputResult = ClipboardUtil.handleTranscriptionOutput(text)

                // Transition to appropriate state
                await MainActor.run {
                    switch outputResult {
                    case .pasted:
                        self.stateManager.finishDecoding(copied: true, pasted: true)
                    case .copied:
                        self.stateManager.finishDecoding(copied: true, pasted: false)
                    case .none:
                        self.stateManager.finishDecoding(copied: false, pasted: false)
                    }
                }

                // Wait for copied/pasted state to show before hiding
                if outputResult != .none {
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                }

            } catch let error as TranscriptionError {
                print("Error transcribing audio: \(error)")
                try? FileManager.default.removeItem(at: tempURL)
                await MainActor.run {
                    self.stateManager.reset()

                    // Show user-friendly error for model issues
                    if case .modelLoadFailed(let reason) = error {
                        self.modelErrorMessage = reason
                        self.showModelError = true
                    }
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
    @Environment(\.openWindow) var openWindow
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

                                        if let shortcutDisplay = currentShortcutDisplayString() {
                                            VStack(spacing: 8) {
                                                Text("Pro Tip:")
                                                    .font(.subheadline)
                                                    .foregroundColor(.secondary)

                                                HStack(spacing: 4) {
                                                    Text("Press")
                                                        .font(.subheadline)
                                                        .foregroundColor(.secondary)
                                                    Text(shortcutDisplay)
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
                    // Bottom bar only - no mic button
                    .safeAreaInset(edge: .bottom) {
                        HStack(alignment: .center) {
                            // Left: shortcut hint (minimal)
                            if let shortcutDisplay = currentShortcutDisplayString() {
                                HStack(spacing: 4) {
                                    Text(shortcutDisplay)
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
                                LanguagePickerIconView()
                                MicrophonePickerIconView(microphoneService: viewModel.microphoneService, permissionsManager: viewModel.permissionsManager, isRecording: viewModel.isRecording)

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
                                    openWindow(id: "settings")
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
        .frame(minWidth: 400, idealWidth: 400)
        .background(Color(NSColor.windowBackgroundColor))
        // Floating mic button overlay - allows click-through to recordings behind
        .overlay(alignment: .bottom) {
            if permissionsManager.isMicrophonePermissionGranted {
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
                            .controlSize(.large)
                            .frame(width: 120, height: 120)
                    case .copied:
                        CopiedButton()
                            .frame(width: 120, height: 120)
                    default:
                        AmplitudeRingRecordButton(state: viewModel.state)
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Circle().size(width: 84, height: 84).offset(x: 18, y: 18))
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
                    .allowsHitTesting(false)
                }
                .padding(.bottom, 52)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.isRecording)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.state)
            }
        }
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
        .alert("Model Not Available", isPresented: $viewModel.showModelError) {
            Button("Open Settings") {
                SettingsNavigation.shared.initialTab = 1  // Model tab
                openWindow(id: "settings")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(viewModel.modelErrorMessage)\n\nPlease download a model in Settings to use transcription.")
        }
        .onAppear {
            // Check if model is missing at launch and show alert
            if let error = TranscriptionService.shared.modelLoadError {
                viewModel.modelErrorMessage = error
                viewModel.showModelError = true
            }
        }
        .focusable()
        .onKeyPress(.space) {
            // Don't capture spacebar if a text field/editor is focused
            if let firstResponder = NSApp.keyWindow?.firstResponder,
               firstResponder is NSTextView || firstResponder is NSText {
                return .ignored
            }

            // Spacebar to toggle recording when app is focused
            if viewModel.state == .idle && !viewModel.isRecording {
                viewModel.startRecording()
                return .handled
            } else if viewModel.isRecording {
                viewModel.startDecoding()
                return .handled
            }
            return .ignored
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

    private var formattedDateTime: String {
        let calendar = Calendar.current
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        let timeString = timeFormatter.string(from: recording.timestamp)

        if calendar.isDateInToday(recording.timestamp) {
            return timeString  // Just show time for today
        } else if calendar.isDateInYesterday(recording.timestamp) {
            return "Yesterday \(timeString)"
        } else {
            // Check if within last 7 days
            let daysAgo = calendar.dateComponents([.day], from: recording.timestamp, to: Date()).day ?? 0
            if daysAgo < 7 {
                let weekdayFormatter = DateFormatter()
                weekdayFormatter.dateFormat = "EEEE"  // Full weekday name
                return "\(weekdayFormatter.string(from: recording.timestamp)) \(timeString)"
            } else {
                // Older: show date
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "MMM d, yyyy"
                return dateFormatter.string(from: recording.timestamp)
            }
        }
    }

    private var trimmedText: String {
        recording.transcription.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Transcription Area
            VStack(alignment: .leading, spacing: 8) {
                Text(trimmedText)
                    .font(Typography.cardBody)
                    .foregroundColor(.primary)
                    .lineSpacing(Typography.cardBodyLineSpacing)
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
                                .font(Typography.cardReadMore)
                                .foregroundColor(.secondary)
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(Typography.cardReadMoreIcon)
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            // Bottom Bar - Metadata + Actions (faded when not hovered)
            HStack(spacing: 0) {
                // Left: Metadata
                HStack(spacing: 6) {
                    Text(formattedDateTime)
                        .font(Typography.cardMeta)
                        .foregroundColor(.secondary)

                    Text("•")
                        .font(Typography.cardMetaSeparator)
                        .foregroundColor(.secondary.opacity(0.4))

                    Text(formattedDuration)
                        .font(Typography.cardMeta)
                        .foregroundColor(.secondary)

                    Text("•")
                        .font(Typography.cardMetaSeparator)
                        .foregroundColor(.secondary.opacity(0.4))

                    Text("\(wordCount) words")
                        .font(Typography.cardMeta)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Right: Action Buttons
                HStack(spacing: 16) {
                    // Play/Stop Button
                    Button(action: togglePlayback) {
                        Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                            .font(Typography.cardActionIcon)
                            .foregroundColor(isPlaying ? .red : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isPlaying ? "Stop" : "Play")

                    // Copy Button
                    Button(action: copyToClipboard) {
                        Image(systemName: showCopyConfirmation ? "checkmark" : "doc.on.doc")
                            .font(Typography.cardActionIcon)
                            .foregroundColor(showCopyConfirmation ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy to clipboard")

                    // Delete Button
                    Button(action: deleteRecording) {
                        Image(systemName: "trash")
                            .font(Typography.cardActionIcon)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete")
                }
            }
            .opacity(isHovered || isPlaying ? 1.0 : 0.4)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
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
                VStack(alignment: .leading, spacing: 4) {
                    Text("Transcription")
                        .font(Typography.detailTitle)
                    Text(recording.timestamp, format: .dateTime.month().day().year().hour().minute())
                        .font(Typography.detailDate)
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
                        .font(Typography.detailBody)
                        .lineSpacing(Typography.detailEditorLineSpacing)
                        .focused($isTextFocused)
                        .frame(maxWidth: .infinity, minHeight: 300)
                        .padding()
                        .onKeyPress(.escape) {
                            isEditing = false
                            return .handled
                        }
                } else {
                    Text(displayText)
                        .font(Typography.detailBody)
                        .lineSpacing(Typography.detailBodyLineSpacing)
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

struct LanguagePickerIconView: View {
    @State private var showMenu = false
    @State private var selectedLanguage = AppPreferences.shared.whisperLanguage

    private var displayCode: String {
        LanguageUtil.shortCodes[selectedLanguage] ?? selectedLanguage.uppercased()
    }

    var body: some View {
        Button(action: {
            showMenu.toggle()
        }) {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text(displayCode)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .help(LanguageUtil.languageNames[selectedLanguage] ?? "Language")
        .popover(isPresented: $showMenu, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(LanguageUtil.availableLanguages, id: \.self) { code in
                    Button(action: {
                        selectedLanguage = code
                        AppPreferences.shared.whisperLanguage = code
                        showMenu = false
                    }) {
                        HStack {
                            Text(LanguageUtil.languageNames[code] ?? code)
                            Spacer()
                            if code == selectedLanguage {
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
            .frame(minWidth: 160)
            .padding(.vertical, 8)
        }
    }
}

struct MicrophonePickerIconView: View {
    @ObservedObject var microphoneService: MicrophoneService
    @ObservedObject var permissionsManager: PermissionsManager
    @StateObject private var meterService = AudioMeterService.shared
    @State private var showMenu = false
    let isRecording: Bool

    private var hasSignal: Bool {
        isRecording && meterService.normalizedAmplitude > 0.05
    }

    private var systemAudioDevices: [MicrophoneService.AudioDevice] {
        microphoneService.availableMicrophones.filter { $0.isSystemAudio }
    }

    private var builtInMicrophones: [MicrophoneService.AudioDevice] {
        microphoneService.availableMicrophones.filter { $0.isBuiltIn && !$0.isSystemAudio }
    }

    private var externalMicrophones: [MicrophoneService.AudioDevice] {
        microphoneService.availableMicrophones.filter { !$0.isBuiltIn && !$0.isSystemAudio }
    }

    private var iconName: String {
        if microphoneService.availableMicrophones.isEmpty {
            return "mic.slash"
        }
        if microphoneService.currentMicrophone?.isSystemAudio == true {
            return "speaker.wave.2.fill"
        }
        return "mic.fill"
    }

    /// Show warning indicator if system audio is selected but permission is missing
    private var showPermissionWarning: Bool {
        microphoneService.currentMicrophone?.isSystemAudio == true &&
        !permissionsManager.isSystemAudioPermissionGranted
    }

    private var deviceDisplayName: String {
        guard let device = microphoneService.currentMicrophone else {
            return "No device"
        }
        // Shorten common names for display
        if device.isSystemAudio {
            return "System Audio"
        }
        return device.name
    }

    var body: some View {
        Button(action: {
            showMenu.toggle()
        }) {
            HStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: iconName)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)

                    // Warning badge when permission is missing
                    if showPermissionWarning {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.orange)
                            .offset(x: 4, y: -4)
                    }
                }

                Text(deviceDisplayName)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                // Signal indicator (only during recording)
                if isRecording {
                    Circle()
                        .fill(hasSignal ? Color.green : Color.gray.opacity(0.5))
                        .frame(width: 6, height: 6)
                        .animation(.easeInOut(duration: 0.15), value: hasSignal)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(6)
            .frame(maxWidth: 150)
        }
        .buttonStyle(.plain)
        .help(showPermissionWarning
              ? "System audio permission required"
              : (microphoneService.currentMicrophone?.displayName ?? "Select audio source"))
        .popover(isPresented: $showMenu, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 0) {
                if microphoneService.availableMicrophones.isEmpty {
                    Text("No audio sources available")
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    // System Audio section
                    ForEach(systemAudioDevices) { device in
                        systemAudioSourceButton(for: device)
                    }

                    // Permission warning and settings button
                    if !systemAudioDevices.isEmpty && !permissionsManager.isSystemAudioPermissionGranted {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                                Text("Permission required")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 12)

                            Button(action: {
                                permissionsManager.openSystemPreferences(for: .systemAudio)
                                showMenu = false
                            }) {
                                HStack {
                                    Image(systemName: "gear")
                                        .frame(width: 16)
                                    Text("Open System Settings")
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.accentColor)
                        }
                        .padding(.bottom, 4)
                    }

                    if !systemAudioDevices.isEmpty && (!builtInMicrophones.isEmpty || !externalMicrophones.isEmpty) {
                        Divider()
                            .padding(.vertical, 4)
                    }

                    // Built-in microphones
                    ForEach(builtInMicrophones) { microphone in
                        audioSourceButton(for: microphone, icon: "mic.fill")
                    }

                    if !builtInMicrophones.isEmpty && !externalMicrophones.isEmpty {
                        Divider()
                            .padding(.vertical, 4)
                    }

                    // External microphones
                    ForEach(externalMicrophones) { microphone in
                        audioSourceButton(for: microphone, icon: "mic.fill")
                    }
                }
            }
            .frame(minWidth: 220)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func systemAudioSourceButton(for device: MicrophoneService.AudioDevice) -> some View {
        Button(action: {
            microphoneService.selectMicrophone(device)
            showMenu = false
        }) {
            HStack {
                Image(systemName: "speaker.wave.2.fill")
                    .frame(width: 16)
                    .foregroundColor(.secondary)
                Text(device.displayName)
                Spacer()
                if !permissionsManager.isSystemAudioPermissionGranted {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                if let current = microphoneService.currentMicrophone,
                   current.id == device.id {
                    Image(systemName: "checkmark")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func audioSourceButton(for device: MicrophoneService.AudioDevice, icon: String) -> some View {
        Button(action: {
            microphoneService.selectMicrophone(device)
            showMenu = false
        }) {
            HStack {
                Image(systemName: icon)
                    .frame(width: 16)
                    .foregroundColor(.secondary)
                Text(device.displayName)
                Spacer()
                if let current = microphoneService.currentMicrophone,
                   current.id == device.id {
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

struct MainRecordButton: View {
    let isRecording: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var idleBackgroundColor: Color {
        colorScheme == .dark
            ? Color.red.opacity(0.25)
            : Color.red.opacity(0.12)
    }

    private var idleRingColor: Color {
        colorScheme == .dark
            ? Color.red.opacity(0.5)
            : Color.red.opacity(0.3)
    }

    private var idleShadowColor: Color {
        colorScheme == .dark
            ? Color.red.opacity(0.3)
            : Color.black.opacity(0.1)
    }

    var body: some View {
        ZStack {
            // Background circle
            Circle()
                .fill(isRecording ? Color.red : idleBackgroundColor)
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
                    .stroke(idleRingColor, lineWidth: 2)
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
        .shadow(color: isRecording ? .red.opacity(0.5) : idleShadowColor, radius: isRecording ? 12 : 4)
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
