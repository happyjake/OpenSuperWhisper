import AVFoundation
import Foundation

@MainActor
class TranscriptionService: ObservableObject {
    static let shared = TranscriptionService()

    @Published private(set) var isTranscribing = false
    @Published private(set) var transcribedText = ""
    @Published private(set) var currentSegment = ""
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Float = 0.0
    @Published private(set) var modelLoadError: String? = nil

    private var context: MyWhisperContext?
    private var totalDuration: Float = 0.0
    private var transcriptionTask: Task<String, Error>? = nil
    private var isCancelled = false
    private var abortFlag: UnsafeMutablePointer<Bool>? = nil

    // Waiters for model loading completion
    private var modelLoadedWaiters: [CheckedContinuation<Void, Never>] = []

    init() {
        loadModel()
    }

    func cancelTranscription() {
        isCancelled = true

        // Set the abort flag to true to signal the whisper processing to stop
        if let abortFlag = abortFlag {
            abortFlag.pointee = true
        }

        transcriptionTask?.cancel()
        transcriptionTask = nil

        // Reset state
        isTranscribing = false
        currentSegment = ""
        progress = 0.0
        isCancelled = false
    }

    deinit {
        // Free the abort flag if it exists
        abortFlag?.deallocate()
    }

    /// Wait for model to be loaded. Returns immediately if already loaded or if loading failed.
    func waitForModelReady() async {
        // If not currently loading, return immediately (either loaded successfully or failed)
        if !isLoading {
            return
        }

        // Wait for model to finish loading
        await withCheckedContinuation { continuation in
            // Double-check in case model finished loading while we were setting up
            if !isLoading {
                continuation.resume()
            } else {
                modelLoadedWaiters.append(continuation)
            }
        }
    }

    private func resumeModelWaiters() {
        for waiter in modelLoadedWaiters {
            waiter.resume()
        }
        modelLoadedWaiters.removeAll()
    }

    private func loadModel() {
        print("Loading model")
        modelLoadError = nil

        guard let modelPath = AppPreferences.shared.selectedModelPath else {
            modelLoadError = "No model selected"
            print("Model loading failed: No model path configured")
            resumeModelWaiters()
            return
        }

        // Check if model file exists
        guard FileManager.default.fileExists(atPath: modelPath) else {
            modelLoadError =
                "Model file not found: \(URL(fileURLWithPath: modelPath).lastPathComponent)"
            print("Model loading failed: File does not exist at \(modelPath)")
            resumeModelWaiters()
            return
        }

        isLoading = true

        Task.detached(priority: .userInitiated) { [weak self] in
            let params = WhisperContextParams()
            let newContext = MyWhisperContext.initFromFile(path: modelPath, params: params)

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.context = newContext
                self.isLoading = false

                if newContext != nil {
                    self.modelLoadError = nil
                    print("Model loaded successfully")
                } else {
                    self.modelLoadError = "Failed to initialize model"
                    print("Model loading failed: Could not initialize context")
                }

                self.resumeModelWaiters()
            }
        }
    }

    func reloadModel(with path: String) {
        print("Reloading model")
        modelLoadError = nil

        // Check if model file exists
        guard FileManager.default.fileExists(atPath: path) else {
            modelLoadError = "Model file not found: \(URL(fileURLWithPath: path).lastPathComponent)"
            print("Model reload failed: File does not exist at \(path)")
            resumeModelWaiters()
            return
        }

        isLoading = true

        Task.detached(priority: .userInitiated) { [weak self] in
            let params = WhisperContextParams()
            let newContext = MyWhisperContext.initFromFile(path: path, params: params)

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.context = newContext
                self.isLoading = false

                if newContext != nil {
                    self.modelLoadError = nil
                    print("Model reloaded successfully")
                } else {
                    self.modelLoadError = "Failed to initialize model"
                    print("Model reload failed: Could not initialize context")
                }

                self.resumeModelWaiters()
            }
        }
    }

    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        // Wait for model to be ready before starting transcription
        await waitForModelReady()

        // Check if model failed to load
        if let error = modelLoadError {
            throw TranscriptionError.modelLoadFailed(error)
        }

        await MainActor.run {
            self.progress = 0.0
            self.isTranscribing = true
            self.transcribedText = ""
            self.currentSegment = ""
            self.isCancelled = false

            // Initialize a new abort flag and set it to false
            if self.abortFlag != nil {
                self.abortFlag?.deallocate()
            }
            self.abortFlag = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
            self.abortFlag?.initialize(to: false)
        }

        defer {
            Task { @MainActor in
                self.isTranscribing = false
                self.currentSegment = ""
                if !self.isCancelled {
                    self.progress = 1.0
                }
                self.transcriptionTask = nil
            }
        }

        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration)
        let durationInSeconds = Float(CMTimeGetSeconds(duration))

        await MainActor.run {
            self.totalDuration = durationInSeconds
        }

        // Get the context and abort flag before detaching to a background task
        let contextForTask = context
        let abortFlagForTask = abortFlag

        // Create and store the task
        let task = Task.detached(priority: .userInitiated) { [self] in
            // Check for cancellation
            try Task.checkCancellation()

            guard let context = contextForTask else {
                throw TranscriptionError.contextInitializationFailed
            }

            guard let samples = try await self.convertAudioToPCM(fileURL: url) else {
                throw TranscriptionError.audioConversionFailed
            }

            // Check for cancellation
            try Task.checkCancellation()

            let nThreads = 4

            guard context.pcmToMel(samples: samples, nSamples: samples.count, nThreads: nThreads)
            else {
                throw TranscriptionError.processingFailed
            }

            // Check for cancellation
            try Task.checkCancellation()

            guard context.encode(offset: 0, nThreads: nThreads) else {
                throw TranscriptionError.processingFailed
            }

            // Check for cancellation
            try Task.checkCancellation()

            var params = WhisperFullParams()

            params.strategy = settings.useBeamSearch ? .beamSearch : .greedy
            params.nThreads = Int32(nThreads)
            params.noTimestamps = !settings.showTimestamps
            params.suppressBlank = settings.suppressBlankAudio
            params.translate = settings.translateToEnglish

            // Determine effective language and prompt
            // For auto-detect mode, detect language first to get the appropriate prompt
            let effectiveLanguageForPrompt: String
            if settings.selectedLanguage == "auto" {
                // Detect language first using the already-encoded audio
                var langProbs = [Float](repeating: 0, count: MyWhisperContext.langMaxId() + 1)
                let detectedLangId = context.langAutoDetect(
                    offsetMs: 0, nThreads: nThreads, langProbs: &langProbs)
                if detectedLangId >= 0, let langStr = MyWhisperContext.langStr(id: detectedLangId) {
                    effectiveLanguageForPrompt = langStr
                    print("TranscriptionService: Pre-detected language for prompt: \(langStr)")
                } else {
                    effectiveLanguageForPrompt = "en"  // Fallback to English
                }
                params.language = nil  // Let whisper confirm via full transcription
            } else {
                effectiveLanguageForPrompt = settings.selectedLanguage
                params.language = settings.selectedLanguage
            }
            params.detectLanguage = false

            params.temperature = Float(settings.temperature)
            params.noSpeechThold = Float(settings.noSpeechThreshold)

            // Use language-specific initial prompt
            let effectivePrompt = settings.getPrompt(for: effectiveLanguageForPrompt)
            params.initialPrompt = effectivePrompt
            if let prompt = effectivePrompt {
                print(
                    "TranscriptionService: Using prompt for \(effectiveLanguageForPrompt): \(prompt)"
                )
            }

            // Set up the abort callback
            typealias GGMLAbortCallback = @convention(c) (UnsafeMutableRawPointer?) -> Bool

            let abortCallback: GGMLAbortCallback = { userData in
                guard let userData = userData else { return false }
                let flag = userData.assumingMemoryBound(to: Bool.self)
                return flag.pointee
            }

            if settings.useBeamSearch {
                params.beamSearchBeamSize = Int32(settings.beamSize)
            }

            params.printRealtime = true
            params.print_realtime = true

            // Set up the segment callback
            let segmentCallback:
                @convention(c) (OpaquePointer?, OpaquePointer?, Int32, UnsafeMutableRawPointer?) ->
                    Void = { ctx, state, n_new, user_data in
                        guard let ctx = ctx,
                            let userData = user_data,
                            let service = Unmanaged<TranscriptionService>.fromOpaque(userData)
                                .takeUnretainedValue() as TranscriptionService?
                        else { return }

                        // Process the segment in a non-isolated context
                        let segmentInfo = service.processNewSegment(
                            context: ctx, state: state, nNew: Int(n_new))

                        // Update UI on the main thread
                        Task { @MainActor in
                            // Check if cancelled
                            if service.isCancelled { return }

                            if !segmentInfo.text.isEmpty {
                                service.currentSegment = segmentInfo.text
                                service.transcribedText += segmentInfo.text + "\n"
                            }

                            if service.totalDuration > 0 && segmentInfo.timestamp > 0 {
                                let newProgress = min(
                                    segmentInfo.timestamp / service.totalDuration, 1.0)
                                service.progress = newProgress
                            }
                        }
                    }

            // Set the callbacks in the params
            params.newSegmentCallback = segmentCallback
            params.newSegmentCallbackUserData = Unmanaged.passUnretained(self).toOpaque()

            // Convert to C params and set the abort callback
            var cParams = params.toC()
            cParams.abort_callback = abortCallback

            // Set the abort flag user data
            if let abortFlag = abortFlagForTask {
                cParams.abort_callback_user_data = UnsafeMutableRawPointer(abortFlag)
            }

            // Check for cancellation
            try Task.checkCancellation()

            guard context.full(samples: samples, params: &cParams) else {
                throw TranscriptionError.processingFailed
            }

            // Check for cancellation
            try Task.checkCancellation()

            var text = ""
            let nSegments = context.fullNSegments

            for i in 0..<nSegments {
                // Check for cancellation periodically
                if i % 5 == 0 {
                    try Task.checkCancellation()
                }

                guard let segmentText = context.fullGetSegmentText(iSegment: i) else { continue }

                if settings.showTimestamps {
                    let t0 = context.fullGetSegmentT0(iSegment: i)
                    let t1 = context.fullGetSegmentT1(iSegment: i)
                    text += String(format: "[%.1f->%.1f] ", Float(t0) / 100.0, Float(t1) / 100.0)
                }
                text += segmentText + "\n"
            }

            let cleanedText =
                text
                .replacingOccurrences(of: "[MUSIC]", with: "")
                .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Determine effective language for autocorrect
            // When auto-detect is used, get the detected language from Whisper
            let effectiveLanguage: String
            if settings.selectedLanguage == "auto" {
                let detectedLangId = context.fullLangId
                effectiveLanguage = MyWhisperContext.langStr(id: detectedLangId) ?? "unknown"
                print("TranscriptionService: Auto-detected language: \(effectiveLanguage)")
            } else {
                effectiveLanguage = settings.selectedLanguage
            }

            // Apply Asian autocorrect if enabled and language is Chinese, Japanese, or Korean
            var processedText = cleanedText
            if ["zh", "ja", "ko"].contains(effectiveLanguage) && settings.useAsianAutocorrect
                && !cleanedText.isEmpty
            {
                print(
                    "TranscriptionService: Applying Asian autocorrect for language: \(effectiveLanguage)"
                )
                processedText = AutocorrectWrapper.format(cleanedText)
            }

            // Apply local LLM post-processing if enabled (llama.cpp)
            if settings.isLLMEnabled && !processedText.isEmpty {
                print(
                    "TranscriptionService: Applying local LLM processing with mode: \(settings.llmProcessingMode.rawValue)"
                )

                // Get the LLM service
                if let llmService = LLMServiceFactory.shared.getService(
                    backend: settings.llmBackendType)
                {
                    // Check readiness
                    let readiness = await llmService.readiness
                    if readiness == .modelLoaded {
                        do {
                            let result = try await llmService.process(
                                text: processedText,
                                mode: settings.llmProcessingMode,
                                customPrompt: settings.llmCustomPrompt
                            )
                            processedText = result.text
                            print(
                                "TranscriptionService: Local LLM processing completed in \(result.processingTimeMs)ms"
                            )
                        } catch {
                            // Log error but preserve original text
                            print(
                                "TranscriptionService: Local LLM processing failed: \(error.localizedDescription)"
                            )
                        }
                    } else if readiness == .modelDownloaded {
                        // Model exists but not loaded - try to load it
                        do {
                            if let modelPath = settings.llmModelPath {
                                try await llmService.loadModel(at: URL(fileURLWithPath: modelPath))
                                let result = try await llmService.process(
                                    text: processedText,
                                    mode: settings.llmProcessingMode,
                                    customPrompt: settings.llmCustomPrompt
                                )
                                processedText = result.text
                                print(
                                    "TranscriptionService: Local LLM processing completed (after load) in \(result.processingTimeMs)ms"
                                )
                            }
                        } catch {
                            print(
                                "TranscriptionService: Local LLM failed to load/process: \(error.localizedDescription)"
                            )
                        }
                    } else {
                        print(
                            "TranscriptionService: Local LLM not ready (state: \(readiness.displayName))"
                        )
                    }
                }
            }

            // Apply LLM editor if enabled (remote API - runs after local LLM)
            let prefs = AppPreferences.shared
            if prefs.editorEnabled && prefs.editorBackend != .disabled && !processedText.isEmpty {
                print(
                    "TranscriptionService: Applying LLM editor with mode: \(prefs.editorOutputMode.rawValue)"
                )

                // Build metadata for editor context
                let metadata = EditorMetadata(
                    audioDurationMs: Int(durationInSeconds * 1000),
                    whisperModel: AppPreferences.shared.selectedModelPath?.components(
                        separatedBy: "/"
                    ).last,
                    detectedLanguage: effectiveLanguage
                )

                // Build glossary from user dictionary (DictionaryManager is @MainActor)
                let glossary = await MainActor.run {
                    let terms = DictionaryManager.shared.dictionary.topTerms(limit: 30).map {
                        entry in
                        DictionaryTerm(
                            term: entry.term,
                            aliases: entry.aliases,
                            caseSensitive: entry.caseSensitive
                        )
                    }
                    #if DEBUG
                        if terms.isEmpty {
                            print(
                                "TranscriptionService: Dictionary is empty, no glossary terms for LLM"
                            )
                        } else {
                            print(
                                "TranscriptionService: Using \(terms.count) glossary terms: \(terms.map { $0.term }.joined(separator: ", "))"
                            )
                        }
                    #endif
                    return terms
                }

                // Run the async editor call (EditorCoordinator handles errors and fallback internally)
                let textToEdit = processedText
                processedText = await EditorCoordinator.shared.edit(
                    raw: textToEdit,
                    mode: prefs.editorOutputMode,
                    glossary: glossary,
                    language: effectiveLanguage,
                    metadata: metadata
                )
                print("TranscriptionService: LLM editor completed")
            }

            let finalText =
                processedText.isEmpty ? "No speech detected in the audio" : processedText

            await MainActor.run {
                if !self.isCancelled {
                    self.transcribedText = finalText
                    self.progress = 1.0
                }
            }

            return finalText
        }

        // Store the task
        await MainActor.run {
            self.transcriptionTask = task
        }

        do {
            return try await task.value
        } catch is CancellationError {
            // Handle cancellation
            await MainActor.run {
                self.isCancelled = true
                // Make sure the abort flag is set to true
                self.abortFlag?.pointee = true
            }
            throw TranscriptionError.processingFailed
        }
    }

    // Make this method nonisolated to be callable from any context
    nonisolated func processNewSegment(context: OpaquePointer, state: OpaquePointer?, nNew: Int)
        -> (text: String, timestamp: Float)
    {
        let nSegments = Int(whisper_full_n_segments(context))
        let startIdx = max(0, nSegments - nNew)

        var newText = ""
        var latestTimestamp: Float = 0

        for i in startIdx..<nSegments {
            guard let cString = whisper_full_get_segment_text(context, Int32(i)) else { continue }
            let segmentText = String(cString: cString)
            newText += segmentText + " "

            let t1 = Float(whisper_full_get_segment_t1(context, Int32(i))) / 100.0
            latestTimestamp = max(latestTimestamp, t1)
        }

        let cleanedText = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleanedText, latestTimestamp)
    }

    // Make this method nonisolated to be callable from any context
    nonisolated func createContext() -> MyWhisperContext? {
        guard let modelPath = AppPreferences.shared.selectedModelPath else {
            return nil
        }

        let params = WhisperContextParams()
        return MyWhisperContext.initFromFile(path: modelPath, params: params)
    }

    nonisolated func convertAudioToPCM(fileURL: URL) async throws -> [Float]? {
        return try await Task.detached(priority: .userInitiated) {
            let audioFile = try AVAudioFile(forReading: fileURL)
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16000,
                channels: 1,
                interleaved: false)!

            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let converter = AVAudioConverter(from: audioFile.processingFormat, to: format)!

            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: audioFile.processingFormat)

            let lengthInFrames = UInt32(audioFile.length)
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(lengthInFrames))

            guard let buffer = buffer else { return nil }

            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                do {
                    let tempBuffer = AVAudioPCMBuffer(
                        pcmFormat: audioFile.processingFormat,
                        frameCapacity: AVAudioFrameCount(inNumPackets))
                    guard let tempBuffer = tempBuffer else {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    try audioFile.read(into: tempBuffer)
                    outStatus.pointee = .haveData
                    return tempBuffer
                } catch {
                    outStatus.pointee = .endOfStream
                    return nil
                }
            }

            converter.convert(
                to: buffer,
                error: &error,
                withInputFrom: inputBlock)

            if let error = error {
                print("Conversion error: \(error)")
                return nil
            }

            guard let channelData = buffer.floatChannelData else { return nil }
            return Array(
                UnsafeBufferPointer(
                    start: channelData[0],
                    count: Int(buffer.frameLength)))
        }.value
    }
}

enum TranscriptionError: LocalizedError {
    case modelLoadFailed(String)
    case contextInitializationFailed
    case audioConversionFailed
    case processingFailed

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let reason):
            return "Model load failed: \(reason)"
        case .contextInitializationFailed:
            return "Failed to initialize transcription context"
        case .audioConversionFailed:
            return "Failed to convert audio"
        case .processingFailed:
            return "Transcription processing failed"
        }
    }
}
