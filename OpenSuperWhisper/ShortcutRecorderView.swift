import Carbon.HIToolbox
import KeyboardShortcuts
import SwiftUI

/// A custom shortcut recorder that supports both traditional key combinations
/// and modifier-only shortcuts (e.g. ⌃⌘).
struct ShortcutRecorderView: View {
    @Binding var shortcutType: ShortcutType
    @StateObject private var recorder = ShortcutRecorderModel()

    var body: some View {
        HStack(spacing: 4) {
            if recorder.isRecording {
                Text(recorder.liveDisplay.isEmpty ? "Type shortcut…" : recorder.liveDisplay)
                    .font(.system(size: 13))
                    .foregroundColor(recorder.liveDisplay.isEmpty ? .secondary : .primary)
            } else {
                Text(recorder.displayText)
                    .font(.system(size: 13))
                    .foregroundColor(recorder.displayText == "Record Shortcut" ? .secondary : .primary)
            }

            if !recorder.isRecording && recorder.hasShortcut {
                Button(action: { clearShortcut() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(minWidth: 120)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(recorder.isRecording ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .onTapGesture {
            if recorder.isRecording {
                recorder.cancelRecording()
            } else {
                recorder.startRecording { type in
                    shortcutType = type
                }
            }
        }
        .onAppear {
            recorder.loadCurrentShortcut()
        }
    }

    private func clearShortcut() {
        KeyboardShortcuts.setShortcut(nil, for: .toggleRecord)
        ModifierShortcutManager.shared.targetShortcut = nil
        AppPreferences.shared.shortcutType = .traditional
        shortcutType = .traditional
        recorder.loadCurrentShortcut()
        ShortcutManager.shared.setupShortcuts()
    }
}

// MARK: - Recorder Model

@MainActor
final class ShortcutRecorderModel: ObservableObject {
    @Published var isRecording = false
    @Published var displayText = "Record Shortcut"
    @Published var liveDisplay = ""
    @Published var hasShortcut = false

    private var flagsMonitor: Any?
    private var keyMonitor: Any?
    private var currentModifiers: NSEvent.ModifierFlags = []
    private var peakModifiers: NSEvent.ModifierFlags = []
    private var onSave: ((ShortcutType) -> Void)?

    func loadCurrentShortcut() {
        let type = AppPreferences.shared.shortcutType
        switch type {
        case .traditional:
            if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecord) {
                displayText = shortcut.description
                hasShortcut = true
            } else {
                displayText = "Record Shortcut"
                hasShortcut = false
            }
        case .modifierOnly:
            if let raw = AppPreferences.shared.modifierShortcutFlags {
                let shortcut = ModifierShortcut(modifierFlagsRawValue: UInt(raw))
                if shortcut.isValid {
                    displayText = shortcut.displayString
                    hasShortcut = true
                } else {
                    displayText = "Record Shortcut"
                    hasShortcut = false
                }
            } else {
                displayText = "Record Shortcut"
                hasShortcut = false
            }
        }
    }

    func startRecording(onSave: @escaping (ShortcutType) -> Void) {
        self.onSave = onSave
        isRecording = true
        liveDisplay = ""
        currentModifiers = []
        peakModifiers = []

        // Disable existing shortcuts while recording
        KeyboardShortcuts.isEnabled = false
        ModifierShortcutManager.shared.isEnabled = false

        // Monitor modifier key changes (flagsChanged)
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        // Monitor regular key presses
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
            return nil // consume the event
        }
    }

    func cancelRecording() {
        endRecording()
    }

    // MARK: - Event Handling

    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option, .control, .shift, .function])

        if flags.isEmpty && !currentModifiers.isEmpty {
            // All modifiers released — try to save using the peak (all modifiers that were held together)
            let shortcut = ModifierShortcut(modifierFlags: peakModifiers)
            if shortcut.isValid {
                saveModifierOnlyShortcut(shortcut)
            } else {
                NSSound.beep()
                liveDisplay = ""
            }
            currentModifiers = []
            peakModifiers = []
            return
        }

        currentModifiers = flags
        // Track the peak: accumulate all modifiers seen since last full release
        peakModifiers = peakModifiers.union(flags)
        liveDisplay = modifierDisplayString(peakModifiers)
    }

    private func handleKeyDown(_ event: NSEvent) {
        // Escape cancels
        if event.keyCode == 53 {
            cancelRecording()
            return
        }

        // Delete/Backspace clears
        if event.keyCode == 51 || event.keyCode == 117 {
            KeyboardShortcuts.setShortcut(nil, for: .toggleRecord)
            ModifierShortcutManager.shared.targetShortcut = nil
            AppPreferences.shared.shortcutType = .traditional
            onSave?(.traditional)
            endRecording()
            loadCurrentShortcut()
            return
        }

        // Traditional shortcut: modifiers + key
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let carbonModifiers = modifiers.carbonModifiers
        let shortcut = KeyboardShortcuts.Shortcut(carbonKeyCode: Int(event.keyCode), carbonModifiers: carbonModifiers)

        KeyboardShortcuts.setShortcut(shortcut, for: .toggleRecord)
        ModifierShortcutManager.shared.targetShortcut = nil
        AppPreferences.shared.shortcutType = .traditional
        onSave?(.traditional)
        endRecording()
        loadCurrentShortcut()
        ShortcutManager.shared.setupShortcuts()
    }

    private func saveModifierOnlyShortcut(_ shortcut: ModifierShortcut) {
        // Clear the traditional shortcut
        KeyboardShortcuts.setShortcut(nil, for: .toggleRecord)
        // Save modifier-only shortcut
        ModifierShortcutManager.shared.targetShortcut = shortcut
        AppPreferences.shared.shortcutType = .modifierOnly
        onSave?(.modifierOnly)
        endRecording()
        loadCurrentShortcut()
        ShortcutManager.shared.setupShortcuts()
    }

    private func endRecording() {
        if let m = flagsMonitor { NSEvent.removeMonitor(m) }
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        flagsMonitor = nil
        keyMonitor = nil
        isRecording = false
        liveDisplay = ""
        currentModifiers = []
        peakModifiers = []

        // Re-enable shortcuts
        KeyboardShortcuts.isEnabled = true
        ModifierShortcutManager.shared.isEnabled = true
    }

    // MARK: - Helpers

    private func modifierDisplayString(_ flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        if flags.contains(.function) { parts.append("fn") }
        return parts.joined()
    }
}

// MARK: - NSEvent.ModifierFlags carbon conversion

extension NSEvent.ModifierFlags {
    /// Convert to Carbon modifier flags for KeyboardShortcuts.Shortcut.
    var carbonModifiers: Int {
        var result = 0
        if contains(.command) { result |= cmdKey }
        if contains(.option) { result |= optionKey }
        if contains(.control) { result |= controlKey }
        if contains(.shift) { result |= shiftKey }
        return result
    }
}

// MARK: - Shortcut display helper for ContentView

/// Returns the display string for the currently configured shortcut, regardless of type.
@MainActor
func currentShortcutDisplayString() -> String? {
    switch AppPreferences.shared.shortcutType {
    case .traditional:
        return KeyboardShortcuts.getShortcut(for: .toggleRecord)?.description
    case .modifierOnly:
        guard let raw = AppPreferences.shared.modifierShortcutFlags else { return nil }
        let shortcut = ModifierShortcut(modifierFlagsRawValue: UInt(raw))
        return shortcut.isValid ? shortcut.displayString : nil
    }
}
