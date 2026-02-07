import AppKit
import ApplicationServices
import Carbon
import Cocoa
import Foundation
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    // Use Cmd+Shift+Space for macOS 15+ compatibility (Option-only shortcuts no longer work)
    static let toggleRecord = Self("toggleRecord", default: .init(.space, modifiers: [.command, .shift]))
    static let escape = Self("escape", default: .init(.escape))
    static let stopRecordingSpace = Self("stopRecordingSpace", default: .init(.space))
}

class ShortcutManager {
    static let shared = ShortcutManager()

    private var holdWorkItem: DispatchWorkItem?
    private let holdThreshold: TimeInterval = 0.3
    private var holdMode = false

    private init() {
        print("ShortcutManager init")
        setupShortcuts()
    }

    // MARK: - Shared recording logic

    /// Handle key-down for the record shortcut (used by both traditional and modifier-only modes).
    func handleKeyDown() {
        // Cancel any pending hold detection
        holdWorkItem?.cancel()
        holdMode = false
        // Perform UI actions on the main actor
        Task { @MainActor in
            let indicatorManager = IndicatorWindowManager.shared
            if !indicatorManager.isVisible {
                self.showIndicatorAndRecord()
            } else if RecordingStateManager.shared.isRecording && !self.holdMode {
                // Second quick press while recording: toggle off
                indicatorManager.stopRecording()
            }
        }
        // Schedule hold-mode flag after threshold
        let workItem = DispatchWorkItem {
            self.holdMode = true
        }
        holdWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: workItem)
    }

    /// Handle key-up for the record shortcut (used by both traditional and modifier-only modes).
    func handleKeyUp() {
        // Cancel hold detection
        holdWorkItem?.cancel()
        holdWorkItem = nil
        // Perform UI actions on the main actor
        Task { @MainActor in
            if self.holdMode && RecordingStateManager.shared.isRecording {
                // End hold-to-record
                IndicatorWindowManager.shared.stopRecording()
                self.holdMode = false
            }
            // Tap-mode toggle off handled on keyDown
        }
    }

    // MARK: - Shortcut setup

    /// Configure shortcuts based on the current user preference. Call this to switch modes at runtime.
    public func setupShortcuts() {
        teardownCurrentShortcuts()

        switch AppPreferences.shared.shortcutType {
        case .traditional:
            setupTraditionalShortcuts()
        case .modifierOnly:
            setupModifierOnlyShortcuts()
        }

        setupStopShortcuts()
    }

    /// Tear down both shortcut systems so we can cleanly switch modes.
    func teardownCurrentShortcuts() {
        // Tear down modifier-only system
        let modManager = ModifierShortcutManager.shared
        modManager.isEnabled = false
        modManager.onTap = nil
        modManager.onHoldStart = nil
        modManager.onHoldEnd = nil
        modManager.stop()

        // Tear down traditional system
        KeyboardShortcuts.disable(.toggleRecord)

        // Reset hold state
        holdWorkItem?.cancel()
        holdWorkItem = nil
        holdMode = false
    }

    /// Set up the traditional KeyboardShortcuts-based record shortcut.
    private func setupTraditionalShortcuts() {
        KeyboardShortcuts.onKeyDown(for: .toggleRecord) { [weak self] in
            self?.handleKeyDown()
        }
        KeyboardShortcuts.onKeyUp(for: .toggleRecord) { [weak self] in
            self?.handleKeyUp()
        }
    }

    /// Show the indicator near the cursor and start recording.
    @MainActor
    private func showIndicatorAndRecord() {
        let indicatorManager = IndicatorWindowManager.shared
        guard !indicatorManager.isVisible else { return }
        let indicatorPoint: NSPoint?
        if let caret = FocusUtils.getCaretRect(), let screen = FocusUtils.getFocusedWindowScreen() {
            indicatorPoint = NSPoint(x: caret.origin.x, y: screen.frame.height - caret.origin.y)
        } else {
            indicatorPoint = FocusUtils.getCurrentCursorPosition()
        }
        let vm = indicatorManager.show(nearPoint: indicatorPoint)
        vm.startRecording()
    }

    /// Set up modifier-only shortcuts via ModifierShortcutManager.
    private func setupModifierOnlyShortcuts() {
        // Disable traditional toggle so it doesn't interfere
        KeyboardShortcuts.disable(.toggleRecord)

        let modManager = ModifierShortcutManager.shared

        // Restore persisted modifier flags if a target isn't already set
        if modManager.targetShortcut == nil, let raw = AppPreferences.shared.modifierShortcutFlags {
            let shortcut = ModifierShortcut(modifierFlagsRawValue: UInt(raw))
            if shortcut.isValid {
                modManager.targetShortcut = shortcut
            }
        }

        // Tap: toggle recording on/off
        modManager.onTap = { [weak self] in
            Task { @MainActor in
                if IndicatorWindowManager.shared.isVisible {
                    IndicatorWindowManager.shared.stopRecording()
                } else {
                    self?.showIndicatorAndRecord()
                }
            }
        }

        // Hold start: begin recording
        modManager.onHoldStart = { [weak self] in
            Task { @MainActor in
                self?.showIndicatorAndRecord()
            }
        }

        // Hold end: stop recording
        modManager.onHoldEnd = {
            Task { @MainActor in
                if IndicatorWindowManager.shared.isVisible {
                    IndicatorWindowManager.shared.stopRecording()
                }
            }
        }

        modManager.isEnabled = true
        modManager.start()
    }

    /// Set up escape and space stop-recording shortcuts (always use KeyboardShortcuts, regardless of mode).
    private func setupStopShortcuts() {
        KeyboardShortcuts.onKeyUp(for: .escape) {
            Task { @MainActor in
                if IndicatorWindowManager.shared.isVisible {
                    IndicatorWindowManager.shared.stopForce()
                }
            }
        }
        KeyboardShortcuts.disable(.escape)

        KeyboardShortcuts.onKeyUp(for: .stopRecordingSpace) {
            Task { @MainActor in
                if IndicatorWindowManager.shared.isVisible {
                    IndicatorWindowManager.shared.stopRecording()
                }
            }
        }
        KeyboardShortcuts.disable(.stopRecordingSpace)
    }
}
