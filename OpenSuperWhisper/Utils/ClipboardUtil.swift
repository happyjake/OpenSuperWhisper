import Cocoa

class ClipboardUtil {

    /// Result of handling transcription output
    enum TranscriptionOutputResult {
        case copied
        case pasted
        case none
    }

    /// Handles transcription output based on user preferences.
    /// Returns the result indicating what action was taken.
    static func handleTranscriptionOutput(_ text: String) -> TranscriptionOutputResult {
        let shouldCopy = AppPreferences.shared.autoCopyToClipboard
        let shouldPaste = AppPreferences.shared.autoPasteAfterCopy && AXIsProcessTrusted()

        if shouldCopy {
            if shouldPaste {
                // Paste and keep transcription on clipboard (don't restore original)
                pasteText(text)
                print("Transcription result (copied and pasted): \(text)")
                return .pasted
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                print("Transcription result (copied to clipboard): \(text)")
                return .copied
            }
        } else {
            print("Transcription result: \(text)")
            return .none
        }
    }

    private static func saveCurrentPasteboardContents() -> ([NSPasteboard.PasteboardType: Any], [NSPasteboard.PasteboardType])? {
        let pasteboard = NSPasteboard.general
        let types = pasteboard.types ?? []

        // If pasteboard is empty, return nil
        guard !types.isEmpty else { return nil }

        var savedContents: [NSPasteboard.PasteboardType: Any] = [:]

        // Save data for each type
        for type in types {
            if let data = pasteboard.data(forType: type) {
                savedContents[type] = data
            } else if let string = pasteboard.string(forType: type) {
                savedContents[type] = string
            } else if let urls = pasteboard.propertyList(forType: type) as? [String] {
                savedContents[type] = urls
            }
        }

        return (!savedContents.isEmpty) ? (savedContents, types) : nil
    }

    private static func restorePasteboardContents(_ contents: ([NSPasteboard.PasteboardType: Any], [NSPasteboard.PasteboardType])) {
        let pasteboard = NSPasteboard.general
        let (savedContents, types) = contents

        pasteboard.declareTypes(types, owner: nil)

        // Restore data for each type
        for (type, content) in savedContents {
            if let data = content as? Data {
                pasteboard.setData(data, forType: type)
            } else if let string = content as? String {
                pasteboard.setString(string, forType: type)
            } else if let urls = content as? [String] {
                pasteboard.setPropertyList(urls, forType: type)
            }
        }
    }

    /// Pastes text by setting it on the clipboard and simulating Cmd+V.
    /// The transcription remains on the clipboard after pasting (user expectation).
    private static func pasteText(_ text: String) {
        let pasteboard = NSPasteboard.general

        // Set text to pasteboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Create event source
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            print("ClipboardUtil: Failed to create CGEventSource")
            return
        }

        // Key codes:
        // - Command (left) — 55
        // - V — 9
        let keyCodeCmd: CGKeyCode = 55
        let keyCodeV: CGKeyCode = 9

        // Create events: press Command, press V, release V, release Command
        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeCmd, keyDown: true) else {
            print("ClipboardUtil: Failed to create cmdDown event")
            return
        }

        guard let vDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true) else {
            print("ClipboardUtil: Failed to create vDown event")
            return
        }
        vDown.flags = .maskCommand

        guard let vUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false) else {
            print("ClipboardUtil: Failed to create vUp event")
            return
        }
        vUp.flags = .maskCommand

        guard let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeCmd, keyDown: false) else {
            print("ClipboardUtil: Failed to create cmdUp event")
            return
        }

        // Define event tap location
        let eventTapLocation = CGEventTapLocation.cghidEventTap

        // Post events to system
        cmdDown.post(tap: eventTapLocation)
        vDown.post(tap: eventTapLocation)
        vUp.post(tap: eventTapLocation)
        cmdUp.post(tap: eventTapLocation)

        // Note: We don't restore the clipboard - user expects transcription to remain available
    }

    /// Legacy method for inserting text using pasteboard with clipboard restoration.
    /// Use handleTranscriptionOutput() for transcription workflow instead.
    static func insertTextUsingPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general

        // Save current pasteboard contents
        let savedContents = saveCurrentPasteboardContents()

        // Set new text to pasteboard
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(text, forType: .string)

        // Create event source
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            print("Failed to create event source")
            // Restore original contents if event source creation failed
            if let contents = savedContents {
                restorePasteboardContents(contents)
            }
            return
        }

        // Key codes (in dec):
        // - Command (left) — 55
        // - V — 9
        let keyCodeCmd: CGKeyCode = 55
        let keyCodeV: CGKeyCode = 9

        // Create events: press Command, press V, release V, release Command
        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeCmd, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeCmd, keyDown: false) else {
            print("ClipboardUtil: Failed to create keyboard events for paste")
            if let contents = savedContents {
                restorePasteboardContents(contents)
            }
            return
        }

        // Set Command flag when pressing V
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        // Define event tap location
        let eventTapLocation = CGEventTapLocation.cghidEventTap

        // Post events to system
        cmdDown.post(tap: eventTapLocation)
        vDown.post(tap: eventTapLocation)
        vUp.post(tap: eventTapLocation)
        cmdUp.post(tap: eventTapLocation)

        // Add a delay to ensure paste operation completes before restoring
        // Using DispatchQueue instead of Thread.sleep for better async behavior
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            // Restore original contents
            if let contents = savedContents {
                restorePasteboardContents(contents)
            }
        }
    }
}
