import AVFoundation
import AppKit
import Foundation
import CoreGraphics

enum Permission {
    case microphone
    case accessibility
    case systemAudio
}

class PermissionsManager: ObservableObject {
    @Published var isMicrophonePermissionGranted = false
    @Published var isAccessibilityPermissionGranted = false
    @Published var isSystemAudioPermissionGranted = false

    /// True if we've determined permission status from actual recording attempt
    private var systemAudioPermissionConfirmed = false

    private var permissionCheckTimer: Timer?

    init() {
        checkMicrophonePermission()
        checkAccessibilityPermission()
        checkSystemAudioPermission()

        // Monitor accessibility permission changes using NSWorkspace's notification center
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityPermissionChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )

        // Listen for system audio permission notifications (detected during actual recording)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSystemAudioPermissionDenied),
            name: .systemAudioPermissionDenied,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSystemAudioPermissionGranted),
            name: .systemAudioPermissionGranted,
            object: nil
        )

        // Start continuous permission checking
        startPermissionChecking()
    }

    deinit {
        stopPermissionChecking()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleSystemAudioPermissionDenied() {
        markSystemAudioPermissionDenied()
    }

    @objc private func handleSystemAudioPermissionGranted() {
        markSystemAudioPermissionGranted()
    }

    private func startPermissionChecking() {
        // Timer is scheduled on the main run loop
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkMicrophonePermission()
            self?.checkAccessibilityPermission()
            self?.checkSystemAudioPermission()
        }
    }

    private func stopPermissionChecking() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
    }

    func checkMicrophonePermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        DispatchQueue.main.async { [weak self] in
            switch status {
            case .authorized:
                self?.isMicrophonePermissionGranted = true
            default:
                self?.isMicrophonePermissionGranted = false
            }
        }
    }

    func checkAccessibilityPermission() {
        let granted = AXIsProcessTrusted()
        DispatchQueue.main.async { [weak self] in
            self?.isAccessibilityPermissionGranted = granted
        }
    }

    func checkSystemAudioPermission() {
        // Don't override if we've already confirmed from actual recording
        guard !systemAudioPermissionConfirmed else { return }

        // Note: macOS 14.4+ has two separate permissions:
        // 1. "Screen & System Audio Recording" - checked by CGPreflightScreenCaptureAccess()
        // 2. "System Audio Recording Only" - NO public API to check this!
        //
        // We check CGPreflightScreenCaptureAccess as a hint, but the real check
        // happens when recording - if we get 0 audio samples, permission is denied.
        //
        // If screen recording is granted, system audio is definitely available.
        // If not, user might still have "System Audio Recording Only" enabled,
        // so we show "unknown" state (assume granted until proven otherwise).
        let screenRecordingGranted = CGPreflightScreenCaptureAccess()
        DispatchQueue.main.async { [weak self] in
            if screenRecordingGranted {
                self?.isSystemAudioPermissionGranted = true
            }
            // Don't set to false if screen recording is denied -
            // user might have "System Audio Recording Only" enabled
        }
    }

    func requestSystemAudioPermission() {
        // Try to trigger the permission dialog
        // Note: This requests full screen recording, not just system audio
        // The "System Audio Recording Only" permission has no public request API
        let _ = CGRequestScreenCaptureAccess()
        checkSystemAudioPermission()
    }

    /// Called when system audio recording fails with 0 samples
    /// This is the only reliable way to detect "System Audio Recording Only" is not granted
    func markSystemAudioPermissionDenied() {
        systemAudioPermissionConfirmed = true
        DispatchQueue.main.async { [weak self] in
            self?.isSystemAudioPermissionGranted = false
        }
    }

    /// Called when system audio recording succeeds
    func markSystemAudioPermissionGranted() {
        systemAudioPermissionConfirmed = true
        DispatchQueue.main.async { [weak self] in
            self?.isSystemAudioPermissionGranted = true
        }
    }

    /// Reset the confirmed flag (e.g., when user changes settings)
    func resetSystemAudioPermissionCheck() {
        systemAudioPermissionConfirmed = false
        checkSystemAudioPermission()
    }

    func requestMicrophonePermissionOrOpenSystemPreferences() {

        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.isMicrophonePermissionGranted = granted
                }
            }
        case .authorized:
            self.isMicrophonePermissionGranted = true
        default:
            openSystemPreferences(for: .microphone)
        }
    }

    @objc private func accessibilityPermissionChanged() {
        checkAccessibilityPermission()
    }

    func openSystemPreferences(for permission: Permission) {
        let urlString: String
        switch permission {
        case .microphone:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .systemAudio:
            // Opens "Screen & System Audio Recording" in System Settings
            // System audio capture is under the screen capture privacy settings
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }

        if let url = URL(string: urlString) {
            DispatchQueue.main.async {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Opens System Preferences to the system audio recording permission page.
    /// Call this when system audio recording permission is denied.
    func openSystemAudioPreferences() {
        openSystemPreferences(for: .systemAudio)
    }
}
