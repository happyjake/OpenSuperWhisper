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
        }
        .handlesExternalEvents(matching: Set(arrayLiteral: "openMainWindow"))
    }

    init() {
        _ = ShortcutManager.shared
        _ = MicrophoneService.shared
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
