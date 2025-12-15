//
//  OpenSuperWhisperApp.swift
//  OpenSuperWhisper
//
//  Created by user on 05.02.2025.
//

import AVFoundation
import SwiftUI
import AppKit
import Combine

@main
struct OpenSuperWhisperApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            Group {
                if !appState.hasCompletedOnboarding {
                    OnboardingView()
                } else {
                    ContentView()
                }
            }
            .frame(width: 450, height: 650)
            .environmentObject(appState)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 450, height: 650)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    NSApp.sendAction(#selector(AppDelegate.openSettings), to: nil, from: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        .handlesExternalEvents(matching: Set(arrayLiteral: "openMainWindow"))

        Window("Settings", id: "settings") {
            SettingsView(initialTab: 0)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 550, height: 700)
        .handlesExternalEvents(matching: Set(arrayLiteral: "settings"))
    }

    init() {
        _ = ShortcutManager.shared
        _ = MicrophoneService.shared
        _ = TranscriptionService.shared  // Start loading model immediately
        WhisperModelManager.shared.ensureDefaultModelPresent()
    }
}

class AppState: ObservableObject {
    @Published var hasCompletedOnboarding: Bool {
        didSet {
            AppPreferences.shared.hasCompletedOnboarding = hasCompletedOnboarding
        }
    }

    init() {
        self.hasCompletedOnboarding = AppPreferences.shared.hasCompletedOnboarding
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?
    private var microphoneService = MicrophoneService.shared
    private var microphoneObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {

        setupStatusBarItem()

        if let window = NSApplication.shared.windows.first {
            self.mainWindow = window

            window.delegate = self
        }

        observeMicrophoneChanges()
    }

    // Handle URL scheme - this works even when app is in background/menu bar only
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleURL(url)
        }
    }

    private func handleURL(_ url: URL) {
        guard url.scheme == "opensuperwhisper" else { return }

        Task { @MainActor in
            switch url.host {
            case "start-recording", "start":
                if !IndicatorWindowManager.shared.isRecording {
                    let point = NSEvent.mouseLocation
                    let vm = IndicatorWindowManager.shared.show(nearPoint: point)
                    vm.startRecording()
                }

            case "stop-recording", "stop":
                IndicatorWindowManager.shared.stopRecording()

            case "cancel-recording", "cancel":
                IndicatorWindowManager.shared.stopForce()

            case "toggle-recording", "toggle":
                if IndicatorWindowManager.shared.isRecording {
                    IndicatorWindowManager.shared.stopRecording()
                } else {
                    let point = NSEvent.mouseLocation
                    let vm = IndicatorWindowManager.shared.show(nearPoint: point)
                    vm.startRecording()
                }

            case "openMainWindow":
                showMainWindow()

            case "settings":
                // Find and show Settings window, or it will be created by the Window scene
                for window in NSApplication.shared.windows {
                    if window.title == "Settings" {
                        window.makeKeyAndOrderFront(nil)
                        NSApplication.shared.activate(ignoringOtherApps: true)
                        return
                    }
                }
                // Window not found - this shouldn't happen as SwiftUI manages Window scenes
                // but we can trigger it via environment if needed

            default:
                print("Unknown URL command: \(url.host ?? "nil")")
            }
        }
    }
    
    private func observeMicrophoneChanges() {
        microphoneObserver = microphoneService.$availableMicrophones
            .sink { [weak self] _ in
                self?.updateStatusBarMenu()
            }
    }
    
    private func setupStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem?.button {
            if let iconImage = NSImage(named: "tray_icon") {
                iconImage.size = NSSize(width: 48, height: 48)
                iconImage.isTemplate = true
                button.image = iconImage
            } else {
                button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "OpenSuperWhisper")
            }
            
            button.action = #selector(statusBarButtonClicked(_:))
            button.target = self
        }
        
        updateStatusBarMenu()
    }
    
    private func updateStatusBarMenu() {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "OpenSuperWhisper", action: #selector(openApp), keyEquivalent: "o"))
        menu.addItem(NSMenuItem.separator())

        let microphoneMenu = NSMenuItem(title: "Audio Source", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let devices = microphoneService.availableMicrophones
        let currentDevice = microphoneService.currentMicrophone

        if devices.isEmpty {
            let noDeviceItem = NSMenuItem(title: "No audio sources available", action: nil, keyEquivalent: "")
            noDeviceItem.isEnabled = false
            submenu.addItem(noDeviceItem)
        } else {
            let systemAudioDevices = devices.filter { $0.isSystemAudio }
            let builtInMicrophones = devices.filter { $0.isBuiltIn && !$0.isSystemAudio }
            let externalMicrophones = devices.filter { !$0.isBuiltIn && !$0.isSystemAudio }

            // System Audio section
            for device in systemAudioDevices {
                let item = NSMenuItem(
                    title: device.displayName,
                    action: #selector(selectMicrophone(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = device
                item.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "System Audio")

                if let current = currentDevice, current.id == device.id {
                    item.state = .on
                }

                submenu.addItem(item)
            }

            if !systemAudioDevices.isEmpty && (!builtInMicrophones.isEmpty || !externalMicrophones.isEmpty) {
                submenu.addItem(NSMenuItem.separator())
            }

            // Built-in microphones
            for microphone in builtInMicrophones {
                let item = NSMenuItem(
                    title: microphone.displayName,
                    action: #selector(selectMicrophone(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = microphone
                item.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Microphone")

                if let current = currentDevice, current.id == microphone.id {
                    item.state = .on
                }

                submenu.addItem(item)
            }

            if !builtInMicrophones.isEmpty && !externalMicrophones.isEmpty {
                submenu.addItem(NSMenuItem.separator())
            }

            // External microphones
            for microphone in externalMicrophones {
                let item = NSMenuItem(
                    title: microphone.displayName,
                    action: #selector(selectMicrophone(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = microphone
                item.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Microphone")

                if let current = currentDevice, current.id == microphone.id {
                    item.state = .on
                }

                submenu.addItem(item)
            }
        }

        microphoneMenu.submenu = submenu
        menu.addItem(microphoneMenu)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem?.menu = menu
    }
    
    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? MicrophoneService.AudioDevice else { return }
        microphoneService.selectMicrophone(device)
        updateStatusBarMenu()
    }
    
    @objc private func statusBarButtonClicked(_ sender: Any) {
        statusItem?.button?.performClick(nil)
    }
    
    @objc private func openApp() {
        showMainWindow()
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc func openSettings() {
        // Open the settings window using URL scheme
        if let url = URL(string: "opensuperwhisper://settings") {
            NSWorkspace.shared.open(url)
        }
    }

    func showMainWindow() {
        NSApplication.shared.setActivationPolicy(.regular)
        
        if let window = mainWindow {
            if !window.isVisible {
                window.makeKeyAndOrderFront(nil)
            }
            window.orderFrontRegardless()
            NSApplication.shared.activate(ignoringOtherApps: true)
        } else {
            let url = URL(string: "openSuperWhisper://openMainWindow")!
            NSWorkspace.shared.open(url)
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}
