import Cocoa
import Foundation

// MARK: - ModifierShortcut

struct ModifierShortcut: Codable, Equatable {
    let modifierFlagsRawValue: UInt

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue)
    }

    var displayString: String {
        var parts: [String] = []
        let flags = modifierFlags
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        if flags.contains(.function) { parts.append("fn") }
        return parts.joined()
    }

    var isValid: Bool {
        var count = 0
        let flags = modifierFlags
        if flags.contains(.control) { count += 1 }
        if flags.contains(.option) { count += 1 }
        if flags.contains(.shift) { count += 1 }
        if flags.contains(.command) { count += 1 }
        if flags.contains(.function) { count += 1 }
        return count >= 2
    }

    init(modifierFlags: NSEvent.ModifierFlags) {
        self.modifierFlagsRawValue = modifierFlags.intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option, .control, .shift, .function])
            .rawValue
    }

    init(modifierFlagsRawValue: UInt) {
        let flags = NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue)
        self.modifierFlagsRawValue = flags.intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option, .control, .shift, .function])
            .rawValue
    }
}

// MARK: - ModifierShortcutManager

/// Detects modifier-only shortcuts globally by polling modifier key state.
///
/// Uses a lightweight timer (50 Hz) to check `NSEvent.modifierFlags` — no event monitors
/// or CGEventTap needed, so the app's event loop is never disturbed.
///
/// - **Tap** (press + release < holdThreshold): fires `onTap` on release.
/// - **Hold** (press held >= holdThreshold): fires `onHoldStart` at the threshold, `onHoldEnd` on release.
class ModifierShortcutManager {
    static let shared = ModifierShortcutManager()

    var targetShortcut: ModifierShortcut? {
        didSet {
            if let shortcut = targetShortcut {
                AppPreferences.shared.modifierShortcutFlags = Int(shortcut.modifierFlagsRawValue)
            } else {
                AppPreferences.shared.modifierShortcutFlags = nil
            }
        }
    }

    var onTap: (() -> Void)?
    var onHoldStart: (() -> Void)?
    var onHoldEnd: (() -> Void)?
    var isEnabled: Bool = true

    // MARK: - Private state

    private enum State {
        case idle
        case activated
        case holding
    }

    private var state: State = .idle
    private var activatedAt: CFAbsoluteTime = 0
    private let holdThreshold: TimeInterval = 0.3
    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 0.02 // 50 Hz — responsive without noticeable CPU cost

    private init() {
        if let raw = AppPreferences.shared.modifierShortcutFlags {
            let shortcut = ModifierShortcut(modifierFlagsRawValue: UInt(raw))
            if shortcut.isValid {
                targetShortcut = shortcut
            }
        }
    }

    deinit { stop() }

    // MARK: - Public API

    func start() {
        guard pollTimer == nil else { return }
        // Use Timer init (not scheduledTimer) to avoid double-scheduling.
        // Add only to .common mode so the timer fires during tracking (menus, scrolling, etc.).
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        state = .idle
    }

    // MARK: - Polling

    private func poll() {
        guard isEnabled, let target = targetShortcut else { return }

        let currentFlags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option, .control, .shift, .function])
        let targetFlags = target.modifierFlags

        switch state {
        case .idle:
            if currentFlags == targetFlags {
                state = .activated
                activatedAt = CFAbsoluteTimeGetCurrent()
            }

        case .activated:
            if currentFlags == targetFlags {
                // Still holding — check if we've passed the hold threshold
                if CFAbsoluteTimeGetCurrent() - activatedAt >= holdThreshold {
                    state = .holding
                    onHoldStart?()
                }
            } else if currentFlags.isStrictSuperset(of: targetFlags) {
                // Added more modifiers (e.g. Cmd+Opt → Cmd+Opt+Shift) — not our shortcut
                state = .idle
            } else {
                // Released at least one target modifier — it's a tap
                state = .idle
                onTap?()
            }

        case .holding:
            if currentFlags != targetFlags {
                state = .idle
                onHoldEnd?()
            }
        }
    }
}
