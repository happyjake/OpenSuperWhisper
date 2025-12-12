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
}

class ShortcutManager {
    static let shared = ShortcutManager()

    private var holdWorkItem: DispatchWorkItem?
    private let holdThreshold: TimeInterval = 0.3
    private var holdMode = false

    private init() {
        print("ShortcutManager init")

        // Handle key down for recording shortcut: start or toggle and detect hold
        KeyboardShortcuts.onKeyDown(for: .toggleRecord) {
            // Cancel any pending hold detection
            self.holdWorkItem?.cancel()
            self.holdMode = false
            // Perform UI actions on the main actor
            Task { @MainActor in
                let indicatorManager = IndicatorWindowManager.shared
                let stateManager = RecordingStateManager.shared

                if !indicatorManager.isVisible {
                    // First press: show indicator and start recording immediately
                    let cursorPosition = FocusUtils.getCurrentCursorPosition()
                    let indicatorPoint: NSPoint?
                    if let caret = FocusUtils.getCaretRect(), let screen = FocusUtils.getFocusedWindowScreen() {
                        let screenHeight = screen.frame.height
                        indicatorPoint = NSPoint(x: caret.origin.x, y: screenHeight - caret.origin.y)
                    } else {
                        indicatorPoint = cursorPosition
                    }
                    let vm = indicatorManager.show(nearPoint: indicatorPoint)
                    vm.startRecording()
                } else if stateManager.isRecording && !self.holdMode {
                    // Second quick press while recording: toggle off
                    indicatorManager.stopRecording()
                }
            }
            // Schedule hold-mode flag after threshold
            let workItem = DispatchWorkItem {
                self.holdMode = true
            }
            self.holdWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + self.holdThreshold, execute: workItem)
        }

        // Handle key up for recording shortcut: end hold if in hold mode
        KeyboardShortcuts.onKeyUp(for: .toggleRecord) {
            // Cancel hold detection
            self.holdWorkItem?.cancel()
            self.holdWorkItem = nil
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

        KeyboardShortcuts.onKeyUp(for: .escape) {
            // Run on the main actor to safely interact with actor-isolated methods
            Task { @MainActor in
                if IndicatorWindowManager.shared.isVisible {
                    IndicatorWindowManager.shared.stopForce()
                }
            }
        }
        KeyboardShortcuts.disable(.escape)
    }

}