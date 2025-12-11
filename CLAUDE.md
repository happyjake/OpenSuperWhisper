# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# First time setup (after cloning)
git submodule update --init --recursive
brew install cmake libomp rust ruby
gem install xcpretty

# Build and run (Debug)
./run.sh

# Build only (no run)
./run.sh build

# Build output location
./Build/Build/Products/Debug/OpenSuperWhisper.app
```

The `run.sh` script:
1. Configures libwhisper via CMake
2. Builds the autocorrect-swift Rust library for Asian language support
3. Copies libomp.dylib (OpenMP for parallel processing)
4. Builds the Xcode project

## Architecture Overview

OpenSuperWhisper is a macOS menu bar app for local speech-to-text transcription using whisper.cpp. It runs entirely offline using downloaded Whisper GGML models.

### Core Services (Singletons)

- **TranscriptionService** (`TranscriptionService.swift`): Main transcription engine. Loads Whisper models, converts audio to PCM, runs inference via `MyWhisperContext`. Handles segment callbacks for real-time progress updates.

- **AudioRecorder** (`AudioRecorder.swift`): Records audio via AVAudioRecorder. Saves 16kHz mono WAV files to temp directory. Singleton shared across UI components.

- **ShortcutManager** (`ShortcutManager.swift`): Global keyboard shortcuts using KeyboardShortcuts library. Default is Option+Backtick. Supports tap-to-toggle and hold-to-record modes with 0.3s hold threshold.

- **MicrophoneService** (`MicrophoneService.swift`): Manages audio input devices. Persists selected microphone to UserDefaults via `AppPreferences`.

- **WhisperModelManager** (`WhisperModelManager.swift`): Manages Whisper model files in `~/Library/Application Support/[BundleID]/whisper-models/`. Downloads models from Hugging Face. Bundles `ggml-tiny.en.bin` as default.

### Whisper C Bindings

The `OpenSuperWhisper/Whis/` directory contains Swift wrappers around whisper.cpp:

- **MyWhisperContext** (`Whis.swift`): Main wrapper class. Handles model loading, PCM-to-mel conversion, encoding, decoding, and full transcription. Exposes segment iteration for results.
- **WhisperFullParams** (`WhisperFullParams.swift`): Swift struct mapping to `whisper_full_params`. Configures transcription (language, timestamps, beam search, callbacks).
- **WhisperContextParams** (`WhisperContextParams.swift`): Context initialization params (GPU, flash attention).

The underlying C library lives in `libwhisper/whisper.cpp` (git submodule).

### UI Components

- **ContentView**: Main window with recordings list, search, and record button
- **IndicatorWindow**: Floating mini-recorder that appears near cursor during global shortcut recording
- **IndicatorWindowManager**: Manages the floating indicator panel lifecycle
- **OnboardingView**: First-run permissions setup
- **SettingsView**: Tab-based settings (shortcuts, model, transcription, advanced)

### Data Flow

1. User presses shortcut or record button
2. `AudioRecorder.startRecording()` saves to temp WAV
3. On stop, `TranscriptionService.transcribeAudio()` is called
4. Audio converted to 16kHz PCM floats
5. Whisper processes via `MyWhisperContext.full()`
6. Results stored in `RecordingStore`, copied to clipboard

### Key Dependencies

- **KeyboardShortcuts**: Global hotkey registration
- **whisper.cpp**: Core ML inference (git submodule in `libwhisper/`)
- **autocorrect-swift**: Rust library for CJK text formatting (in `asian-autocorrect/`)
- **libomp**: OpenMP for parallel processing

### Preferences

`AppPreferences` (`Utils/AppPreferences.swift`) stores settings in UserDefaults:
- Model path, language, temperature, beam search settings
- Microphone selection (serialized as Data)
- UI state (onboarding completed, sound on record)
