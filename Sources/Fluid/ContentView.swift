//
//  ContentView.swift
//  fluid
//
//  Created by Barathwaj Anandan on 7/30/25.
//

import SwiftUI
import AppKit
import AVFoundation
import Combine
import CoreAudio
import CoreGraphics

// Visualization types moved to UI/Visualization

// Removed inline default animations (now modular)

// Import the talking animations from TalkingAnimations.swift
// The TalkingAudioVisualizationView is now defined in TalkingAnimations.swift

// MARK: - Listening Overlay View (using modular components)
struct ListeningOverlayView: View
{
    var audioLevelPublisher: AnyPublisher<CGFloat, Never>?
    
    var body: some View
    {
        TalkingListeningOverlayView(
            audioLevelPublisher: audioLevelPublisher ?? Empty().eraseToAnyPublisher()
        )
    }
}

// MARK: - Example of switching animation styles
/*
// To use a different animation, simply replace the ListeningOverlayView implementation:

struct PulseListeningOverlayView: View {
    let audioLevelPublisher: AnyPublisher<CGFloat, Never>
    
    var body: some View {
        PulseAudioVisualizationView(
            audioLevelPublisher: audioLevelPublisher ?? Empty().eraseToAnyPublisher(),
            config: PulseAnimationConfig()
        )
    }
}

// Then update ContentView to use PulseListeningOverlayView instead of ListeningOverlayView
// in the .onChange modifier where the overlay is shown.
*/

// ListeningOverlayController moved to Services/

// HotkeyShortcut moved to Models/

// GlobalHotkeyManager moved to Services/

// MARK: - Minimal FluidAudio ASR Service (finalized text, macOS)

// MARK: - Saved Provider Model
// Removed deprecated inline service and model

struct ContentView: View {
    @StateObject private var audioObserver = AudioHardwareObserver()
    @StateObject private var asr = ASRService()
    @StateObject private var mouseTracker = MousePositionTracker()
    @EnvironmentObject private var menuBarManager: MenuBarManager
    @State private var hotkeyManager: GlobalHotkeyManager? = nil
    @State private var hotkeyManagerInitialized: Bool = false
    @State private var overlay: ListeningOverlayController? = nil
    
    @State private var appear = false
    @State private var accessibilityEnabled = false
    @State private var hotkeyShortcut: HotkeyShortcut = SettingsStore.shared.hotkeyShortcut
    @State private var isRecordingShortcut = false
    @State private var pendingModifierFlags: NSEvent.ModifierFlags = []
    @State private var pendingModifierKeyCode: UInt16?
    @State private var pendingModifierOnly = false
    @FocusState private var isTranscriptionFocused: Bool
    
    @State private var overlayVisible: Bool = false
    @State private var overlayAudioLevelThrottled: Any? = nil
    
    @State private var selectedSidebarItem: SidebarItem? = .welcome
    @State private var playgroundUsed: Bool = false
    @State private var recordingAppInfo: (name: String, bundleId: String, windowTitle: String)? = nil

    // Audio Settings Tab State
    @State private var visualizerNoiseThreshold: Double = SettingsStore.shared.visualizerNoiseThreshold
    @State private var inputDevices: [AudioDevice.Device] = []
    @State private var outputDevices: [AudioDevice.Device] = []
    @State private var selectedInputUID: String = SettingsStore.shared.preferredInputDeviceUID ?? ""
    @State private var selectedOutputUID: String = SettingsStore.shared.preferredOutputDeviceUID ?? ""
    
    // AI Prompts Tab State
    @State private var aiInputText: String = ""
    @State private var aiOutputText: String = ""
    @State private var isCallingAI: Bool = false
    @State private var openAIBaseURL: String = "https://api.openai.com/v1"
    
    // MARK: - AI Enhancement checkbox state
    @State private var enableAIProcessing: Bool = false
    @State private var enableDebugLogs: Bool = SettingsStore.shared.enableDebugLogs
    @State private var pressAndHoldModeEnabled: Bool = SettingsStore.shared.pressAndHoldMode
    @State private var enableStreamingPreview: Bool = SettingsStore.shared.enableStreamingPreview

    // Preferences Tab State
    @State private var launchAtStartup: Bool = SettingsStore.shared.launchAtStartup
    @State private var showInDock: Bool = SettingsStore.shared.showInDock
    @State private var showRestartPrompt: Bool = false
    @State private var didOpenAccessibilityPane: Bool = false
    private let accessibilityRestartFlagKey = "FluidVoice_AccessibilityRestartPending"
    
    // MARK: - Voice Recognition Model Management
    // Models scoped by provider (name -> [models])
    @State private var availableModelsByProvider: [String: [String]] = [:]
    @State private var selectedModelByProvider: [String: String] = [:]
    @State private var availableModels: [String] = ["gpt-4.1"] // derived from currentProvider
    @State private var selectedModel: String = "gpt-4.1" // derived from currentProvider
    @State private var showingAddModel: Bool = false
    @State private var newModelName: String = ""
    
    // MARK: - Provider Management
    @State private var providerAPIKeys: [String: String] = [:] // [providerKey: apiKey]
    @State private var currentProvider: String = "openai" // canonical key: "openai" | "groq" | "custom:<id>"

    // API Connection Testing States
    @State private var isTestingConnection: Bool = false
    @State private var connectionStatus: ConnectionStatus = .unknown
    @State private var connectionErrorMessage: String = ""
    @State private var showHelp: Bool = false

    enum ConnectionStatus {
        case unknown, testing, success, failed
    }
    @State private var savedProviders: [SettingsStore.SavedProvider] = []
    @State private var selectedProviderID: String = "openai"
    @State private var showingSaveProvider: Bool = false
    @State private var newProviderName: String = ""
    @State private var newProviderModels: String = ""
    @State private var newProviderApiKey: String = ""
    @State private var showAPIKeyEditor: Bool = false
    @State private var newProviderBaseURL: String = ""
    @State private var keyJustSaved: Bool = false
    
    // Feedback State
    @State private var feedbackText: String = ""
    @State private var feedbackEmail: String = ""
    @State private var includeDebugLogs: Bool = false
    @State private var isSendingFeedback: Bool = false
    @State private var showFeedbackConfirmation: Bool = false

    var body: some View {
        NavigationSplitView {
            sidebarView
                .environmentObject(mouseTracker)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } detail: {
            detailView
                .environmentObject(mouseTracker)
        }
        .withMouseTracking(mouseTracker)
        .environmentObject(mouseTracker)
        .onAppear {
            appear = true
            accessibilityEnabled = checkAccessibilityPermissions()
            // If a previous run set a pending restart, clear it now on fresh launch
            if UserDefaults.standard.bool(forKey: accessibilityRestartFlagKey) {
                UserDefaults.standard.set(false, forKey: accessibilityRestartFlagKey)
                showRestartPrompt = false
            }
            // Ensure no restart UI shows if we already have trust
            if accessibilityEnabled { showRestartPrompt = false }
            
            // Initialize menu bar after app is ready (prevents window server crash)
            menuBarManager.initializeMenuBar()
            
            // Configure menu bar manager with ASR service
            menuBarManager.configure(asrService: asr)
            
            // Initialize hotkey manager with improved timing and validation
            initializeHotkeyManagerIfNeeded()
            if overlay == nil {
                overlay = ListeningOverlayController(asrService: asr)
            }
            
            if overlayAudioLevelThrottled == nil {
                overlayAudioLevelThrottled = asr.audioLevelPublisher as Any
            }
            // Load devices and defaults
            refreshDevices()
            if selectedInputUID.isEmpty, let defIn = AudioDevice.getDefaultInputDevice()?.uid { selectedInputUID = defIn }
            if selectedOutputUID.isEmpty, let defOut = AudioDevice.getDefaultOutputDevice()?.uid { selectedOutputUID = defOut }
            // Apply saved preferences if present and available
            if let prefIn = SettingsStore.shared.preferredInputDeviceUID,
               prefIn.isEmpty == false,
               inputDevices.first(where: { $0.uid == prefIn }) != nil,
               prefIn != AudioDevice.getDefaultInputDevice()?.uid
            {
                _ = AudioDevice.setDefaultInputDevice(uid: prefIn)
                selectedInputUID = prefIn
            }
            if let prefOut = SettingsStore.shared.preferredOutputDeviceUID,
               prefOut.isEmpty == false,
               outputDevices.first(where: { $0.uid == prefOut }) != nil,
               prefOut != AudioDevice.getDefaultOutputDevice()?.uid
            {
                _ = AudioDevice.setDefaultOutputDevice(uid: prefOut)
                selectedOutputUID = prefOut
            }
            
            // Preload ASR model on app startup (with small delay to let app initialize)
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay
                await preloadASRModel()
            }
            
            NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
                let eventModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
                let shortcutModifiers = hotkeyShortcut.modifierFlags.intersection([.command, .option, .control, .shift])
                
                DebugLogger.shared.debug("NSEvent \(event.type) keyCode=\(event.keyCode) recordingShortcut=\(isRecordingShortcut)", source: "ContentView")

                if event.type == .keyDown {
                    if event.keyCode == hotkeyShortcut.keyCode && eventModifiers == shortcutModifiers {
                        DebugLogger.shared.debug("NSEvent monitor: Global hotkey matched on keyDown, passing event through (GlobalHotkeyManager handles)", source: "ContentView")
                        return event
                    }

                    guard isRecordingShortcut else {
                        if event.keyCode == 53 && asr.isRunning {
                            DebugLogger.shared.debug("NSEvent monitor: Escape pressed, cancelling ASR recording", source: "ContentView")
                            asr.stopWithoutTranscription()
                            return nil
                        }
                        resetPendingShortcutState()
                        return event
                    }
                    
                    let keyCode = event.keyCode
                    if keyCode == 53 {
                        DebugLogger.shared.debug("NSEvent monitor: Escape pressed, cancelling shortcut recording", source: "ContentView")
                        isRecordingShortcut = false
                        resetPendingShortcutState()
                        return nil
                    }
                    
                    let combinedModifiers = pendingModifierFlags.union(eventModifiers)
                    let newShortcut = HotkeyShortcut(keyCode: keyCode, modifierFlags: combinedModifiers)
                    DebugLogger.shared.debug("NSEvent monitor: Recording new shortcut: \(newShortcut.displayString)", source: "ContentView")
                    hotkeyShortcut = newShortcut
                    SettingsStore.shared.hotkeyShortcut = newShortcut
                    hotkeyManager?.updateShortcut(newShortcut)
                    isRecordingShortcut = false
                    resetPendingShortcutState()
                    DebugLogger.shared.debug("NSEvent monitor: Finished recording shortcut, isRecordingShortcut set to false", source: "ContentView")
                    return nil
                } else if event.type == .flagsChanged {
                    if hotkeyShortcut.modifierFlags.isEmpty {
                        let isModifierKeyPressed = eventModifiers.isEmpty == false
                        if event.keyCode == hotkeyShortcut.keyCode && isModifierKeyPressed {
                            DebugLogger.shared.debug("NSEvent monitor: Global hotkey matched on flagsChanged, passing event through (GlobalHotkeyManager handles)", source: "ContentView")
                            return event
                        }
                    }

                    guard isRecordingShortcut else {
                        resetPendingShortcutState()
                        return event
                    }

                    if eventModifiers.isEmpty {
                        if pendingModifierOnly, let modifierKeyCode = pendingModifierKeyCode {
                            let newShortcut = HotkeyShortcut(keyCode: modifierKeyCode, modifierFlags: [])
                            DebugLogger.shared.debug("NSEvent monitor: Recording modifier-only shortcut: \(newShortcut.displayString)", source: "ContentView")
                            hotkeyShortcut = newShortcut
                            SettingsStore.shared.hotkeyShortcut = newShortcut
                            hotkeyManager?.updateShortcut(newShortcut)
                            isRecordingShortcut = false
                            resetPendingShortcutState()
                            DebugLogger.shared.debug("NSEvent monitor: Finished recording modifier shortcut, isRecordingShortcut set to false", source: "ContentView")
                            return nil
                        }

                        resetPendingShortcutState()
                        DebugLogger.shared.debug("NSEvent monitor: Modifiers released without recording, continuing to wait", source: "ContentView")
                        return nil
                    }

                    // Modifiers are currently pressed
                    var actualKeyCode = event.keyCode
                    if eventModifiers.contains(.command) {
                        actualKeyCode = (event.keyCode == 55) ? 55 : 54 // 55 = left cmd, 54 = right cmd
                    } else if eventModifiers.contains(.option) {
                        actualKeyCode = (event.keyCode == 58) ? 58 : 61 // 58 = left opt, 61 = right opt
                    } else if eventModifiers.contains(.control) {
                        actualKeyCode = (event.keyCode == 59) ? 59 : 62 // 59 = left ctrl, 62 = right ctrl
                    } else if eventModifiers.contains(.shift) {
                        actualKeyCode = (event.keyCode == 56) ? 56 : 60 // 56 = left shift, 60 = right shift
                    }

                    pendingModifierFlags = eventModifiers
                    pendingModifierKeyCode = actualKeyCode
                    pendingModifierOnly = true
                    DebugLogger.shared.debug("NSEvent monitor: Modifier key pressed during recording, pending modifiers: \(pendingModifierFlags)", source: "ContentView")
                    return nil
                }
                
                return event
            }
        }
        .onChange(of: accessibilityEnabled) { enabled in
            if enabled && hotkeyManager != nil && !hotkeyManagerInitialized {
                DebugLogger.shared.debug("Accessibility enabled, reinitializing hotkey manager", source: "ContentView")
                hotkeyManager?.reinitialize()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            let trusted = AXIsProcessTrusted()
            if trusted != accessibilityEnabled {
                accessibilityEnabled = trusted
            }
        }
        .overlay(alignment: .center) {
        }
        .onReceive(audioObserver.changePublisher) { _ in
            // Hardware change detected → refresh lists and apply preferences if available
            refreshDevices()

            // Input: prefer saved device if present, else mirror system default
            if let prefIn = SettingsStore.shared.preferredInputDeviceUID,
               prefIn.isEmpty == false,
               inputDevices.first(where: { $0.uid == prefIn }) != nil,
               prefIn != AudioDevice.getDefaultInputDevice()?.uid
            {
                _ = AudioDevice.setDefaultInputDevice(uid: prefIn)
                selectedInputUID = prefIn
            }
            else if let sysIn = AudioDevice.getDefaultInputDevice()?.uid
            {
                selectedInputUID = sysIn
            }

            // Output: prefer saved device if present, else mirror system default
            if let prefOut = SettingsStore.shared.preferredOutputDeviceUID,
               prefOut.isEmpty == false,
               outputDevices.first(where: { $0.uid == prefOut }) != nil,
               prefOut != AudioDevice.getDefaultOutputDevice()?.uid
            {
                _ = AudioDevice.setDefaultOutputDevice(uid: prefOut)
                selectedOutputUID = prefOut
            }
            else if let sysOut = AudioDevice.getDefaultOutputDevice()?.uid
            {
                selectedOutputUID = sysOut
            }
        }
        .onDisappear {
            asr.stopWithoutTranscription()
            overlay?.hide()
        }
        .onChange(of: hotkeyShortcut) { newValue in
            DebugLogger.shared.debug("Hotkey shortcut changed to \(newValue.displayString)", source: "ContentView")
            hotkeyManager?.updateShortcut(newValue)

            // Update initialization status after shortcut change
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.hotkeyManagerInitialized = self.hotkeyManager?.validateEventTapHealth() ?? false
                DebugLogger.shared.debug("Hotkey manager initialized: \(self.hotkeyManagerInitialized)", source: "ContentView")
            }
        }
        .onChange(of: asr.isRunning) { running in
            // Prevent rapid state changes that could cause cycles
            guard overlayVisible != running else { return }
            
            let delay: DispatchTimeInterval = .milliseconds(150)
            if running {
                overlayVisible = true
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard self.overlayVisible else { return }
                    let hosting = NSHostingView(rootView: ListeningOverlayView(audioLevelPublisher: self.asr.audioLevelPublisher))
                    hosting.wantsLayer = true
                    hosting.layer?.cornerRadius = 20
                    hosting.layer?.masksToBounds = true
                    self.overlay?.show(with: hosting, showPreview: self.enableStreamingPreview)
                }
            } else {
                overlayVisible = false
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard !self.overlayVisible else { return }
                    self.overlay?.hide()
                    // Clear transcription text when hiding overlay
                    self.overlay?.updateTranscriptionText("")
                }
            }
        }
        .onChange(of: asr.partialTranscription) { newText in
            // Update overlay with streaming transcription preview (if enabled)
            if enableStreamingPreview {
                overlay?.updateTranscriptionText(newText)
            }
        }
    }

    private func resetPendingShortcutState()
    {
        pendingModifierFlags = []
        pendingModifierKeyCode = nil
        pendingModifierOnly = false
    }

    private var sidebarView: some View {
        List(selection: $selectedSidebarItem) {
            NavigationLink(value: SidebarItem.welcome) {
                Label("Welcome", systemImage: "house.fill")
                    .font(.system(size: 15, weight: .medium))
            }
            .listRowBackground(sidebarRowBackground)

            NavigationLink(value: SidebarItem.recording) {
                Label("Recording", systemImage: "mic.fill")
                    .font(.system(size: 15, weight: .medium))
            }
            .listRowBackground(sidebarRowBackground)

            NavigationLink(value: SidebarItem.aiProcessing) {
                Label("AI Processing", systemImage: "sparkles")
                    .font(.system(size: 15, weight: .medium))
            }
            .listRowBackground(sidebarRowBackground)
            
            NavigationLink(value: SidebarItem.audio) {
                Label("Audio", systemImage: "speaker.wave.2.fill")
                    .font(.system(size: 15, weight: .medium))
            }
            .listRowBackground(sidebarRowBackground)
            
            NavigationLink(value: SidebarItem.settings) {
                Label("Settings", systemImage: "gearshape.fill")
                    .font(.system(size: 15, weight: .medium))
            }
            .listRowBackground(sidebarRowBackground)

            NavigationLink(value: SidebarItem.meetingTools) {
                Label("Meeting Tools", systemImage: "person.2.wave.2.fill")
                    .font(.system(size: 15, weight: .medium))
            }
            .listRowBackground(sidebarRowBackground)

            NavigationLink(value: SidebarItem.feedback) {
                Label("Feedback", systemImage: "envelope.fill")
                    .font(.system(size: 15, weight: .medium))
            }
            .listRowBackground(sidebarRowBackground)
        }
        .listStyle(.sidebar)
        .navigationTitle("FluidVoice")
        .background(sidebarBackground)
        .scrollContentBackground(.hidden)
    }
    
    private var sidebarRowBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.ultraThinMaterial.opacity(0.8))
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.10, green: 0.12, blue: 0.20).opacity(0.3), // Deep blue tint
                                Color(red: 0.06, green: 0.08, blue: 0.15).opacity(0.2), // Blue-charcoal
                                Color(red: 0.04, green: 0.05, blue: 0.10).opacity(0.1)  // Dark blue
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
            )
    }
    
    private var sidebarBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.10, green: 0.12, blue: 0.22), // Deep blue-charcoal (more blue at top)
                Color(red: 0.06, green: 0.08, blue: 0.16), // Rich blue-black
                Color(red: 0.04, green: 0.05, blue: 0.10), // Ultra dark blue
                Color(red: 0.02, green: 0.03, blue: 0.06)  // Deepest blue
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
    
    private var detailView: some View {
        ZStack {
            // Tech blue gradient background
            ZStack {
                // Base dark blue layer
                Color(red: 0.04, green: 0.05, blue: 0.09)

                // Tech blue gradient overlay
                LinearGradient(
                    colors: [
                        Color(red: 0.08, green: 0.10, blue: 0.18).opacity(0.8), // Deep tech blue (more blue)
                        Color(red: 0.05, green: 0.07, blue: 0.14).opacity(0.6), // Rich blue-black
                        Color(red: 0.06, green: 0.06, blue: 0.12).opacity(0.7), // Blue-charcoal
                        Color(red: 0.04, green: 0.05, blue: 0.10).opacity(0.5)  // Base dark blue
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                // Subtle radial gradient for depth
                RadialGradient(
                    colors: [
                        Color.clear,
                        Color(red: 0.02, green: 0.03, blue: 0.06).opacity(0.3)
                    ],
                    center: .center,
                    startRadius: 100,
                    endRadius: 400
                )
            }
            .ignoresSafeArea()
            
            Group {
                switch selectedSidebarItem ?? .welcome {
                case .welcome:
                    welcomeView
                case .recording:
                    recordingView
                case .aiProcessing:
                    aiProcessingView
                case .audio:
                    audioView
                case .settings:
                    settingsView
                case .meetingTools:
                    meetingToolsView
                case .feedback:
                    feedbackView
                }
            }
        }
    }

    // MARK: - Welcome Guide
    private var welcomeView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "book.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading) {
                            Text("Welcome to FluidVoice")
                                .font(.system(size: 28, weight: .bold))
                            Text("Your AI-powered voice transcription assistant")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Follow this quick setup to start using FluidVoice.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                .padding(.bottom, 8)

                // Quick Setup Checklist
                HoverableGlossyCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.blue)
                            Text("Quick Setup")
                                .font(.headline)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            SetupStepView(
                                step: 1,
                                title: "Grant Microphone Permission",
                                description: "Allow FluidVoice to access your microphone for voice input",
                                status: asr.micStatus == .authorized ? .completed : .pending,
                                action: {
                                    selectedSidebarItem = .recording
                                }
                            )

                            SetupStepView(
                                step: 2,
                                title: "Enable Accessibility",
                                description: "Grant accessibility permission to type text into other apps",
                                status: accessibilityEnabled ? .completed : .pending,
                                action: {
                                    selectedSidebarItem = .recording
                                }
                            )

                            SetupStepView(
                                step: 3,
                                title: "Set Up AI Enhancement (Optional)",
                                description: "Configure API keys for AI-powered text enhancement",
                                status: {
                                    let hasApiKey = providerAPIKeys[currentProvider]?.isEmpty == false
                                    let isLocal = isLocalEndpoint(openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
                                    let hasModel = availableModels.contains(selectedModel)
                                    return ((isLocal || hasApiKey) && hasModel) ? .completed : .pending
                                }(),
                                action: {
                                    selectedSidebarItem = .aiProcessing
                                }
                            )

                            SetupStepView(
                                step: 4,
                                title: "Test Your Setup below",
                                description: "Try the playground below to test your complete setup",
                                status: playgroundUsed ? .completed : .pending,
                                action: {
                                    // No action needed - playground is right below
                                },
                                showConfigureButton: false
                            )
                        }
                    }
                    .padding(20)
                }

                // Test Playground - Right after setup checklist
                HoverableGlossyCard(excludeInteractiveElements: true) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "text.bubble")
                                .font(.title2)
                                .foregroundStyle(.white)
                            Text("Test Playground")
                                .font(.title3)
                                .fontWeight(.semibold)

                            Spacer()

                            if !asr.finalText.isEmpty {
                                Button(action: {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(asr.finalText, forType: .string)
                                }) {
                                    HStack {
                                        Image(systemName: "doc.on.doc")
                                        Text("Copy")
                                    }
                                }
                                .buttonStyle(InlineButtonStyle())
                                .buttonHoverEffect()
                            }
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Test your voice transcription here!")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .foregroundStyle(.secondary)

                                    Text("• Click 'Start Recording' or use hotkey (Right Option/Alt)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Text("• Speak naturally - words appear in real-time")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Text("• Click 'Stop Recording' when finished")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 4) {
                                    if asr.isRunning {
                                        HStack {
                                            Image(systemName: "waveform")
                                                .foregroundStyle(.red)
                                            Text("Recording...")
                                                .font(.caption)
                                                .foregroundStyle(.red)
                                        }
                                    } else if !asr.finalText.isEmpty {
                                        Text("\(asr.finalText.count) characters")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }

                            // Recording Controls
                            HStack(spacing: 16) {
                                if asr.isRunning {
                                    Button(action: {
                                        Task {
                                            await stopAndProcessTranscription()
                                        }
                                    }) {
                                        HStack(spacing: 8) {
                                            Image(systemName: "stop.fill")
                                                .foregroundStyle(.red)
                                            Text("Stop Recording")
                                                .fontWeight(.medium)
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                        .background(Color.red.opacity(0.1))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                } else {
                                    Button(action: {
                                        startRecording()
                                    }) {
                                        HStack(spacing: 8) {
                                            Image(systemName: "mic.fill")
                                                .foregroundStyle(.green)
                                            Text("Start Recording")
                                                .fontWeight(.medium)
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                        .background(Color.green.opacity(0.1))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                }

                                if !asr.isRunning && !asr.finalText.isEmpty {
                                    Button("Clear Results") {
                                        asr.finalText = ""
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }

                            // TRANSCRIPTION TEXT AREA - ACTUAL TEXT FIELD
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("Transcription Playground")
                                        .font(.headline)
                                        .fontWeight(.semibold)

                                    Spacer()

                                    if !asr.finalText.isEmpty {
                                        Text("\(asr.finalText.count) characters")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                // REAL TEXT EDITOR - Can receive focus and display transcription
                                TextEditor(text: $asr.finalText)
                                    .font(.system(size: 16))
                                    .focused($isTranscriptionFocused)
                                    .frame(height: 200)
                                    .padding(16)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(asr.isRunning ? Color.blue.opacity(0.05) : Color.gray.opacity(0.05))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 12)
                                                    .stroke(asr.isRunning ? Color.blue.opacity(0.3) : Color.gray.opacity(0.2), lineWidth: asr.isRunning ? 2 : 1)
                                            )
                                    )
                                    .overlay(
                                        VStack {
                                            if asr.isRunning {
                                                VStack(spacing: 12) {
                                                    // Animated recording indicator overlay
                                                    HStack(spacing: 8) {
                                                        Image(systemName: "waveform")
                                                            .font(.system(size: 24))
                                                            .foregroundStyle(.blue)
                                                            .scaleEffect(1.0)
                                                            .animation(.easeInOut(duration: 0.8).repeatForever(), value: asr.isRunning)

                                                        Image(systemName: "waveform")
                                                            .font(.system(size: 20))
                                                            .foregroundStyle(.blue.opacity(0.7))
                                                            .scaleEffect(1.0)
                                                            .animation(.easeInOut(duration: 0.6).repeatForever(), value: asr.isRunning)

                                                        Image(systemName: "waveform")
                                                            .font(.system(size: 16))
                                                            .foregroundStyle(.blue.opacity(0.5))
                                                            .scaleEffect(1.0)
                                                            .animation(.easeInOut(duration: 0.4).repeatForever(), value: asr.isRunning)
                                                    }

                                                    VStack(spacing: 4) {
                                                        Text("Listening... Speak now!")
                                                            .font(.title3)
                                                            .fontWeight(.semibold)
                                                            .foregroundStyle(.blue)

                                                        Text("Your words will appear here in real-time")
                                                            .font(.subheadline)
                                                            .foregroundStyle(.blue.opacity(0.8))
                                                    }
                                                }
                                            } else if asr.finalText.isEmpty {
                                                VStack(spacing: 12) {
                                                    Image(systemName: "text.bubble")
                                                        .font(.system(size: 32))
                                                        .foregroundStyle(.secondary.opacity(0.6))

                                                    VStack(spacing: 4) {
                                                        Text("Ready to test!")
                                                            .font(.title3)
                                                            .fontWeight(.semibold)
                                                            .foregroundStyle(.primary)

                                                        Text("Click 'Start Recording' or press your hotkey")
                                                            .font(.subheadline)
                                                            .foregroundStyle(.secondary)
                                                    }
                                                }
                                            }
                                        }
                                        .allowsHitTesting(false) // Don't block text editor interaction
                                    )

                                // Quick Action Buttons
                                if !asr.finalText.isEmpty {
                                    HStack(spacing: 12) {
                                        Button(action: {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(asr.finalText, forType: .string)
                                        }) {
                                            HStack(spacing: 6) {
                                                Image(systemName: "doc.on.doc")
                                                Text("Copy Text")
                                            }
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 8)
                                            .background(Color.blue.opacity(0.1))
                                            .foregroundStyle(.blue)
                                            .cornerRadius(8)
                                        }

                                        Button("Clear & Test Again") {
                                            asr.finalText = ""
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.regular)

                                        Spacer()
                                    }
                                    .padding(.top, 8)
                                }
                            }
                        }
                    }
                    .padding(20)
                }

                // How to Use
                HoverableGlossyCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "play.fill")
                                .foregroundStyle(.green)
                            Text("How to Use")
                                .font(.headline)
                        }

                        VStack(alignment: .leading, spacing: 16) {
                            InstructionStep(
                                number: 1,
                                title: "Start Recording",
                                description: "Use your hotkey (default: Right Option/Alt) or click the record button in the main window"
                            )

                            InstructionStep(
                                number: 2,
                                title: "Speak Clearly",
                                description: "Speak your text naturally. The app works best in quiet environments"
                            )

                            InstructionStep(
                                number: 3,
                                title: "AI Enhancement",
                                description: "Your speech is transcribed, then enhanced by AI for better grammar and clarity"
                            )

                            InstructionStep(
                                number: 4,
                                title: "Auto-Type Result",
                                description: "The enhanced text is automatically typed into your focused application"
                            )
                        }
                    }
                    .padding(20)
                }

                // API Configuration Guide
                HoverableGlossyCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "key.fill")
                                .foregroundStyle(.purple)
                            Text("Get API Keys")
                                .font(.headline)
                        }

                        VStack(alignment: .leading, spacing: 16) {
                            Text("Choose your AI provider:")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            ProviderGuide(
                                name: "OpenAI",
                                url: "https://platform.openai.com/api-keys",
                                description: "Most popular choice with GPT-4.1 models",
                                baseURL: "https://api.openai.com/v1",
                                keyPrefix: "sk-"
                            )

                            ProviderGuide(
                                name: "Groq",
                                url: "https://console.groq.com/keys",
                                description: "Fast inference with Llama and Mixtral models",
                                baseURL: "https://api.groq.com/openai/v1",
                                keyPrefix: "gsk_"
                            )


                            // Local Models Coming Soon
                            HoverableGlossyCard(excludeInteractiveElements: true) {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("Local Models")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(.secondary)

                                        Spacer()

                                        Text("Coming Soon")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.orange)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 2)
                                            .background(Color.orange.opacity(0.1))
                                            .cornerRadius(8)
                                    }

                                    Text("Run models locally for privacy and offline use")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(12)
                            }
                        }
                    }
                    .padding(20)
                }


            }
            .padding(20)
        }
    }

    // MARK: - Getting Started Helper Views

    private struct SetupStepView: View {
        let step: Int
        let title: String
        let description: String
        let status: SetupStatus
        let action: () -> Void
        var showConfigureButton: Bool = true

        enum SetupStatus {
            case pending, completed, inProgress
        }

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.2))
                        .frame(width: 32, height: 32)

                    if status == .completed {
                        Image(systemName: "checkmark")
                            .foregroundStyle(statusColor)
                            .font(.system(size: 14, weight: .bold))
                    } else {
                        Text("\(step)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(statusColor)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))

                        Spacer()

                        if status != .completed && showConfigureButton {
                            Button("Configure") {
                                action()
                            }
                            .font(.system(size: 12))
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    Text(description)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
        }

        private var statusColor: Color {
            switch status {
            case .completed: return .green
            case .inProgress: return .blue
            case .pending: return .secondary
            }
        }
    }



    private struct InstructionStep: View {
        let number: Int
        let title: String
        let description: String

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.2))
                        .frame(width: 28, height: 28)

                    Text("\(number)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.blue)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))

                    Text(description)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private struct ProviderGuide: View {
        let name: String
        let url: String
        let description: String
        let baseURL: String
        let keyPrefix: String

        var body: some View {
            HoverableGlossyCard(excludeInteractiveElements: true) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(name)
                            .font(.system(size: 14, weight: .semibold))

                        Spacer()

                        if !url.isEmpty {
                            Button("Get API Key") {
                                if let url = URL(string: url) {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .font(.system(size: 12))
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    Text(description)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Base URL:")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(baseURL)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }

                        HStack {
                            Text("Key Format:")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(keyPrefix == "not-needed" ? "Not required" : "Starts with: \(keyPrefix)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.primary)
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(12)
            }
        }
    }



    private var microphonePermissionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                // Status indicator
                Circle()
                    .fill(asr.micStatus == .authorized ? .green : .red)
                    .frame(width: 10, height: 10)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(labelFor(status: asr.micStatus))
                        .fontWeight(.medium)
                        .foregroundStyle(asr.micStatus == .authorized ? .primary : Color.red)
                    
                    if asr.micStatus != .authorized {
                        Text("Microphone access is required for voice recording")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                
                microphoneActionButton
            }
            
            // Step-by-step instructions when microphone is not authorized
            if asr.micStatus != .authorized {
                microphoneInstructionsView
            }
        }
    }
    
    private var microphoneActionButton: some View {
        Group {
            if asr.micStatus == .notDetermined {
                Button {
                    asr.requestMicAccess()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "mic.fill")
                        Text("Grant Access")
                            .fontWeight(.medium)
                    }
                }
                .buttonStyle(GlassButtonStyle())
                .buttonHoverEffect()
            } else if asr.micStatus == .denied {
                Button {
                    asr.openSystemSettingsForMic()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "gear")
                        Text("Open Settings")
                            .fontWeight(.medium)
                    }
                }
                .buttonStyle(GlassButtonStyle())
                .buttonHoverEffect()
            }
        }
    }
    
    private var microphoneInstructionsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue)
                    .font(.caption)
                Text("How to enable microphone access:")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                if asr.micStatus == .notDetermined {
                    instructionStep(number: "1", text: "Click **Grant Access** above")
                    instructionStep(number: "2", text: "Choose **Allow** in the system dialog")
                } else if asr.micStatus == .denied {
                    instructionStep(number: "1", text: "Click **Open Settings** above")
                    instructionStep(number: "2", text: "Find **FluidVoice** in the microphone list")
                    instructionStep(number: "3", text: "Toggle **FluidVoice ON** to allow access")
                }
            }
            .padding(.leading, 4)
        }
        .padding(12)
        .background(Color.blue.opacity(0.1))
        .cornerRadius(8)
    }
    
    private func instructionStep(number: String, text: String) -> some View {
        HStack(spacing: 8) {
            Text(number + ".")
                .font(.caption2)
                .foregroundStyle(.blue)
                .fontWeight(.semibold)
                .frame(width: 16)
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Settings View
    private var settingsView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 24) {
                // Header
                HoverableGlossyCard {
                    VStack(spacing: 16) {
                        HStack {
                            Image(systemName: "gear")
                                .font(.system(size: 32))
                                .foregroundStyle(.white)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Settings")
                                    .font(.title2)
                                    .fontWeight(.bold)
                                Text("App behavior and preferences")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()
                        }
                    }
                    .padding(24)
                }

                // Settings Card
                HoverableGlossyCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "power")
                                .font(.title2)
                                .foregroundStyle(.white)
                            Text("App Settings")
                                .font(.title3)
                                .fontWeight(.semibold)
                        }

                        VStack(spacing: 16) {
                            Toggle(isOn: Binding(
                                get: { SettingsStore.shared.launchAtStartup },
                                set: { SettingsStore.shared.launchAtStartup = $0 }
                            )) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Launch at startup")
                                        .font(.headline)
                                    Text("Automatically start FluidVoice when you log in")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.switch)

                            Text("Note: Requires app to be signed for this to work.")
                                .font(.caption2)
                                .foregroundStyle(.secondary.opacity(0.7))

                            Divider()

                            Toggle(isOn: Binding(
                                get: { SettingsStore.shared.showInDock },
                                set: { SettingsStore.shared.showInDock = $0 }
                            )) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Show in Dock")
                                        .font(.headline)
                                    Text("Display FluidVoice icon in the Dock")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.switch)

                            Text("Note: May require app restart to take effect.")
                                .font(.caption2)
                                .foregroundStyle(.secondary.opacity(0.7))
                        }
                    }
                    .padding(24)
                }
            }
            .padding(24)
        }
    }

    private var recordingView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 24) {
                // Hero Header Card
                HoverableGlossyCard {
                    VStack(spacing: 16) {
                        HStack {
                            Image(systemName: "waveform.circle.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(.white)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Voice Dictation")
                                    .font(.title2)
                                    .fontWeight(.bold)
                                Text("AI-powered speech recognition")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()
                        }

                        // Status and Recording Control
                        VStack(spacing: 12) {
                            // Status indicator
                            HStack {
                                Circle()
                                    .fill(asr.isRunning ? .red : asr.isAsrReady ? .green : .secondary)
                                    .frame(width: 8, height: 8)

                                Text(asr.isRunning ? "Recording..." : asr.isAsrReady ? "Ready to record" : "Model not ready")
                                    .font(.subheadline)
                                    .foregroundStyle(asr.isRunning ? .red : asr.isAsrReady ? .green : .secondary)
                            }

                            // Recording Control (Single Toggle Button)
                            Button(action: {
                                if asr.isRunning {
                                    Task {
                                        await stopAndProcessTranscription()
                                    }
                                } else {
                                    startRecording()
                                }
                            }) {
                                HStack {
                                    Image(systemName: asr.isRunning ? "stop.fill" : "mic.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                    Text(asr.isRunning ? "Stop Recording" : "Start Recording")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(PremiumButtonStyle(isRecording: asr.isRunning))
                            .buttonHoverEffect()
                            .scaleEffect(asr.isRunning ? 1.05 : 1.0)
                            .animation(.spring(response: 0.3), value: asr.isRunning)
                            .disabled(!asr.isAsrReady && !asr.isRunning)
                        }
                    }
                    .padding(24)
                }
                .modifier(CardAppearAnimation(delay: 0.1, appear: $appear))

                // Permissions Card
                HoverableGlossyCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "shield.checkered")
                                .font(.title2)
                                .foregroundStyle(.white)
                            Text("Permissions")
                                .font(.title3)
                                .fontWeight(.semibold)
                        }
                        
                        microphonePermissionView
                    }
                    .padding(24)
                }
                .modifier(CardAppearAnimation(delay: 0.2, appear: $appear))

                // Model Configuration Card (disable hover transforms to avoid AppKit constraint logs)
                HoverableGlossyCard(excludeInteractiveElements: true) {
                    VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "brain.head.profile")
                            .font(.title2)
                            .foregroundStyle(.white)
                        Text("Voice to Text Model")
                            .font(.title3)
                            .fontWeight(.semibold)
                    }
                    
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            Text("Model")
                                .fontWeight(.medium)
                            Spacer()
                            Menu(asr.selectedModel.displayName) {
                                ForEach(ASRService.ModelOption.allCases) { option in
                                    Button(option.displayName) { asr.selectedModel = option }
                                }
                            }
                            .disabled(asr.isRunning)
                        }
                        
                        Text(getModelStatusText())
                            .font(.caption)
                            .foregroundStyle(asr.isAsrReady ? .white : .secondary)
                            .padding(.leading, 4)
                        
                        Text("Automatically detects and transcribes 25 European languages")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)

                        // Model status indicator (non-clickable)
                        HStack {
                            if asr.isDownloadingModel {
                                VStack(alignment: .leading, spacing: 4) {
                                    ProgressView(value: max(0.0, min(1.0, asr.modelDownloadProgress)))
                                        .frame(width: 160)
                                    Text(String(format: "Downloading Model… %d%%", Int(asr.modelDownloadProgress * 100)))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else if asr.isAsrReady {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("Model Ready")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.white)
                            } else {
                                Image(systemName: "arrow.down.circle")
                                    .foregroundStyle(.orange)
                                Text("Model will download when needed")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(.ultraThinMaterial.opacity(0.3))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(.white.opacity(0.1), lineWidth: 1)
                                )
                        )

                        // Helpful link: Supported languages
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "link")
                                .foregroundStyle(.secondary)
                            Link(
                                "Supported languages",
                                destination: URL(string: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3")!
                            )
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        
                    }
                }
                .padding(24)
                }
                .modifier(CardAppearAnimation(delay: 0.3, appear: $appear))


                // Global Hotkey Card
                HoverableGlossyCard {
                    VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "keyboard")
                            .font(.title2)
                            .foregroundStyle(.white)
                        Text("Global Hotkey")
                            .font(.title3)
                            .fontWeight(.semibold)
                    }
                    
                    if accessibilityEnabled {
                        VStack(alignment: .leading, spacing: 16) {
                            // Current Hotkey Display
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Current Hotkey")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.secondary)
                                
                                // Hotkey Display Row
                                HStack(spacing: 16) {
                                    // Clean Hotkey Display
                                    HStack(spacing: 8) {
                                        Text(hotkeyShortcut.displayString)
                                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(.primary)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .fill(.quaternary.opacity(0.5))
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 8)
                                                            .stroke(.primary.opacity(0.2), lineWidth: 1)
                                                    )
                                            )
                                    }
                                    
                                    Spacer()
                                    
                                    // Enhanced Change Button
                                    Button {
                                        DebugLogger.shared.debug("Starting to record new shortcut", source: "ContentView")
                                        isRecordingShortcut = true
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: "pencil")
                                                .font(.system(size: 13, weight: .semibold))
                                            Text("Change")
                                                .fontWeight(.semibold)
                                        }
                                    }
                                    .buttonStyle(GlassButtonStyle())
                                    .buttonHoverEffect()
                                    
                                // Restart button for accessibility changes
                                if !hotkeyManagerInitialized && accessibilityEnabled {
                                    Button {
                                        DebugLogger.shared.debug("User requested app restart for accessibility changes", source: "ContentView")
                                        restartApp()
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "arrow.clockwise.circle")
                                                .font(.system(size: 12, weight: .semibold))
                                            Text("Restart")
                                                .font(.system(size: 12, weight: .semibold))
                                        }
                                    }
                                    .buttonStyle(InlineButtonStyle())
                                    .buttonHoverEffect()
                                }
                                }
                            }
                            
                            // Enhanced Status/Instruction Text
                            HStack(spacing: 10) {
                                if isRecordingShortcut {
                                    Image(systemName: "hand.point.up.left.fill")
                                        .foregroundStyle(.white)
                                        .font(.system(size: 16, weight: .medium))
                                    Text("Press your new hotkey combination now...")
                                        .font(.system(.subheadline, weight: .medium))
                                        .foregroundStyle(.white)
                                } else if hotkeyManagerInitialized {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.system(size: 16))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Global Shortcut Active")
                                            .font(.system(.caption, weight: .semibold))
                                            .foregroundStyle(.white)
                                        Text(pressAndHoldModeEnabled
                                             ? "Hold \(hotkeyShortcut.displayString) to record and release to stop"
                                             : "Press \(hotkeyShortcut.displayString) anywhere to start/stop recording")
                                            .font(.system(.caption))
                                            .foregroundStyle(.secondary)
                                    }
                                } else {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                        .frame(width: 16, height: 16)
                                        .foregroundStyle(.orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Hotkey Initializing...")
                                            .font(.system(.caption, weight: .semibold))
                                            .foregroundStyle(.orange)
                                        Text("Please wait while the global hotkey system starts up")
                                            .font(.system(.caption))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.ultraThinMaterial.opacity(0.5))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(.white.opacity(0.1), lineWidth: 1)
                                    )
                            )
                            VStack(alignment: .leading, spacing: 12) {
                                Toggle("Press and Hold Mode", isOn: $pressAndHoldModeEnabled)
                                    .toggleStyle(GlassToggleStyle())
                                Text("When enabled, the shortcut only records while you hold it down, giving you quick push-to-talk style control.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.ultraThinMaterial.opacity(0.5))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(.white.opacity(0.08), lineWidth: 1)
                                    )
                            )
                            .onChange(of: pressAndHoldModeEnabled) { newValue in
                                SettingsStore.shared.pressAndHoldMode = newValue
                                hotkeyManager?.enablePressAndHoldMode(newValue)
                            }
                            
                            VStack(alignment: .leading, spacing: 12) {
                                Toggle("Show Live Preview", isOn: $enableStreamingPreview)
                                    .toggleStyle(GlassToggleStyle())
                                Text("Display transcription text in real-time in the overlay as you speak. When disabled, only the animation is shown.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.ultraThinMaterial.opacity(0.5))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(.white.opacity(0.08), lineWidth: 1)
                                    )
                            )
                            .onChange(of: enableStreamingPreview) { newValue in
                                SettingsStore.shared.enableStreamingPreview = newValue
                                // Dynamically resize overlay based on preview state
                                overlay?.setPreviewEnabled(newValue)
                                // Clear overlay text if disabled
                                if !newValue {
                                    overlay?.updateTranscriptionText("")
                                }
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(spacing: 12) {
                                // Status indicator
                                Circle()
                                    .fill(.red)
                                    .frame(width: 10, height: 10)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(.orange)
                                        Text("Accessibility permissions required")
                                            .fontWeight(.medium)
                                            .foregroundStyle(Color.red)
                                    }
                                    Text("Required for global hotkey functionality")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                
                                Button("Open Accessibility Settings") {
                                    openAccessibilitySettings()
                                } 
                                .buttonStyle(GlassButtonStyle())
                                .buttonHoverEffect()
                            }
                            
                            // Prominent step-by-step instructions
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 8) {
                                    Image(systemName: "info.circle.fill")
                                        .foregroundStyle(.blue)
                                        .font(.caption)
                                    Text("Follow these steps to enable Accessibility:")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .foregroundStyle(.secondary)
                                }
                                
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 8) {
                                        Text("1.")
                                            .font(.caption2)
                                            .foregroundStyle(.blue)
                                            .fontWeight(.semibold)
                                            .frame(width: 16)
                                        Text("Click **Open Accessibility Settings** above")
                                            .font(.caption)
                                            .foregroundStyle(.primary)
                                    }
                                    HStack(spacing: 8) {
                                        Text("2.")
                                            .font(.caption2)
                                            .foregroundStyle(.blue)
                                            .fontWeight(.semibold)
                                            .frame(width: 16)
                                        Text("In the Accessibility window, click the **+ button**")
                                            .font(.caption)
                                            .foregroundStyle(.primary)
                                    }
                                    HStack(spacing: 8) {
                                        Text("3.")
                                            .font(.caption2)
                                            .foregroundStyle(.blue)
                                            .fontWeight(.semibold)
                                            .frame(width: 16)
                                        Text("Navigate to Applications and select **FluidVoice**")
                                            .font(.caption)
                                            .foregroundStyle(.primary)
                                    }
                                    HStack(spacing: 8) {
                                        Text("4.")
                                            .font(.caption2)
                                            .foregroundStyle(.blue)
                                            .fontWeight(.semibold)
                                            .frame(width: 16)
                                        Text("Click **Open**, then toggle **FluidVoice ON** in the list")
                                            .font(.caption)
                                            .foregroundStyle(.primary)
                                    }
                                }
                                .padding(.leading, 4)
                                
                                // Helper buttons
                                HStack(spacing: 12) {
                                    Button("Reveal FluidVoice in Finder") { 
                                        revealAppInFinder() 
                                    }
                                    .buttonStyle(InlineButtonStyle())
                                    .buttonHoverEffect()
                                    
                                    Button("Open Applications Folder") { 
                                        openApplicationsFolder() 
                                    }
                                    .buttonStyle(InlineButtonStyle())
                                    .buttonHoverEffect()
                                }
                            }
                            .padding(12)
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(8)
                        }
                    }
                }
                .padding(24)
                }
                .modifier(CardAppearAnimation(delay: 0.5, appear: $appear))

                // Debug Settings Card
                HoverableGlossyCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "ladybug.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                            Text("Debug Settings")
                                .font(.title3)
                                .fontWeight(.semibold)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            Button {
                                let url = FileLogger.shared.currentLogFileURL()
                                if FileManager.default.fileExists(atPath: url.path) {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                } else {
                                    DebugLogger.shared.info("Log file not found at \(url.path)", source: "ContentView")
                                }
                            } label: {
                                Label("Reveal Log File", systemImage: "doc.richtext")
                                    .labelStyle(.titleAndIcon)
                            }
                            .buttonStyle(GlassButtonStyle())
                            .buttonHoverEffect()

                            Text("Click to reveal the debug log file. This file contains detailed information about app operations and can help with troubleshooting issues.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 4)
                        }
                    }
                }
                .padding(24)
                .modifier(CardAppearAnimation(delay: 0.6, appear: $appear))

            }
            .padding(24)
        }
    }

    // MARK: - AI Prompts Tab
    private var aiProcessingView: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header Section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "sparkles")
                        .font(.title2)
                        .foregroundStyle(.blue)
                    Text("AI Post-Processing")
                        .font(.title2)
                        .fontWeight(.bold)
                    Spacer()
                    Button(action: { showHelp.toggle() }) {
                        Image(systemName: "questionmark.circle")
                            .font(.title3)
                            .foregroundStyle(.blue.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .buttonHoverEffect()
                }

                Text("Enhance your transcriptions with AI. Configure your API, test prompts, and see how AI improves punctuation, grammar, and formatting.")
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                // AI Enhancement Toggle
                HStack(spacing: 16) {
                    Toggle("Enable AI Enhancement", isOn: $enableAIProcessing)
                        .toggleStyle(GlassToggleStyle())
                        .onChange(of: enableAIProcessing) { newValue in
                            SettingsStore.shared.enableAIProcessing = newValue
                        }
                    
                    Spacer()
                    
                    // Only show API key warning for non-local endpoints
                    if enableAIProcessing && 
                       !isLocalEndpoint(openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) && 
                       (providerAPIKeys[currentProvider] ?? "").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("API Key required")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.orange.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(.vertical, 8)
                .onAppear {
                    // Ensure the toggle reflects persisted value when navigating between tabs
                    enableAIProcessing = SettingsStore.shared.enableAIProcessing
                }

                // Help Section
                if showHelp {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "lightbulb.fill")
                                .foregroundStyle(.yellow)
                            Text("Quick Start Guide")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 8) {
                                Text("1.")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                Text("Add your API key and test the connection")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            HStack(alignment: .top, spacing: 8) {
                                Text("2.")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                Text("Choose an AI model for post-processing")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            HStack(alignment: .top, spacing: 8) {
                                Text("3.")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                Text("Test prompts to see how AI improves transcriptions")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Divider()

                        HStack {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.orange)
                            Text("Pro Tips")
                                .font(.caption)
                                .fontWeight(.semibold)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("• Test with actual transcription samples for best results")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("• Include context about your typical speaking style")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("• Experiment with different AI models for various improvements")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                    .background(Color.blue.opacity(0.05))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                    )
                    .transition(.opacity)
                }
            }
            .padding(.bottom, 8)

            // Status Overview
            HoverableGlossyCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "info.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.blue)
                        Text("Setup Status")
                            .font(.headline)
                            .fontWeight(.semibold)
                    }

                    // Status indicators
                    HStack(spacing: 16) {
                        // API Key status (or local endpoint indicator)
                        HStack(spacing: 4) {
                            let hasApiKey = !(providerAPIKeys[currentProvider] ?? "").isEmpty
                            let isLocal = isLocalEndpoint(openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
                            let isConfigured = hasApiKey || isLocal
                            
                            Image(systemName: isConfigured ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(isConfigured ? .green : .red)
                                .font(.caption)
                            Text(isLocal ? "Local" : "API Key")
                                .font(.caption)
                                .foregroundStyle(isConfigured ? .green : .red)
                        }

                        // Connection status
                        HStack(spacing: 4) {
                            Image(systemName: connectionStatus == .success ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(connectionStatus == .success ? .green : .secondary)
                                .font(.caption)
                            Text("Connection")
                                .font(.caption)
                                .foregroundStyle(connectionStatus == .success ? .green : .secondary)
                        }

                        // Model status
                        HStack(spacing: 4) {
                            Image(systemName: availableModels.contains(selectedModel) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(availableModels.contains(selectedModel) ? .green : .secondary)
                                .font(.caption)
                            Text("Model")
                                .font(.caption)
                                .foregroundStyle(availableModels.contains(selectedModel) ? .green : .secondary)
                        }
                    }
                }
                .padding(16)
            }
            .modifier(CardAppearAnimation(delay: 0.05, appear: $appear))

            // API Configuration Section
            HoverableGlossyCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "key.fill")
                            .font(.title3)
                            .foregroundStyle(.blue)
                        Text("API Configuration")
                            .font(.headline)
                            .fontWeight(.semibold)
                    }

            // Saved Providers Dropdown
            // Provider Selection
            HStack(spacing: 8) {
                Text("Provider:")
                Picker("Provider", selection: $selectedProviderID) {
                    // Built-in providers
                    Text("OpenAI").tag("openai")
                    Text("Groq").tag("groq")
                    
                    if !savedProviders.isEmpty {
                        Divider()
                        ForEach(savedProviders) { provider in
                            Text(provider.name).tag(provider.id)
                        }
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 180, alignment: .leading)
                .layoutPriority(1)
                .onChange(of: selectedProviderID) { newValue in
                    switch newValue {
                    case "openai":
                        openAIBaseURL = "https://api.openai.com/v1"
                        updateCurrentProvider()
                        let key = "openai"
                        if let stored = availableModelsByProvider[key], !stored.isEmpty { availableModels = stored }
                        else { availableModels = defaultModels(for: key) }
                        if let sel = selectedModelByProvider[key], availableModels.contains(sel) { selectedModel = sel }
                        else { selectedModel = availableModels.first ?? selectedModel }
                    case "groq":
                        openAIBaseURL = "https://api.groq.com/openai/v1"
                        updateCurrentProvider()
                        let key = "groq"
                        if let stored = availableModelsByProvider[key], !stored.isEmpty { availableModels = stored }
                        else { availableModels = defaultModels(for: key) }
                        if let sel = selectedModelByProvider[key], availableModels.contains(sel) { selectedModel = sel }
                        else { selectedModel = availableModels.first ?? selectedModel }
                    default:
                        if let provider = savedProviders.first(where: { $0.id == newValue }) {
                            openAIBaseURL = provider.baseURL
                            updateCurrentProvider()
                            // Load the saved API key for this provider
                            providerAPIKeys[currentProvider] = provider.apiKey
                            saveProviderAPIKeys()
                            // Load provider-specific models
                            let key = providerKey(for: newValue)
                            availableModels = provider.models.isEmpty ? (availableModelsByProvider[key] ?? defaultModels(for: key)) : provider.models
                            if let sel = selectedModelByProvider[key], availableModels.contains(sel) { selectedModel = sel }
                            else { selectedModel = availableModels.first ?? selectedModel }
                        }
                    }
                }
                
                Spacer()
                
                Button("+ Add Provider") {
                    showingSaveProvider = true
                    newProviderName = ""
                    newProviderBaseURL = ""
                    newProviderApiKey = ""
                    newProviderModels = ""
                }
                .buttonStyle(GlassButtonStyle())
                .buttonHoverEffect()
            }

            // Delete button for custom providers - positioned near model catalogs
            HStack(spacing: 8) {
                // Delete button for custom providers
                if !selectedProviderID.isEmpty && selectedProviderID != "openai" && selectedProviderID != "groq" {
                    Button(action: {
                        // Remove the provider
                        savedProviders.removeAll { $0.id == selectedProviderID }
                        saveSavedProviders()
                        
                        // Remove associated data
                        let key = providerKey(for: selectedProviderID)
                        availableModelsByProvider.removeValue(forKey: key)
                        selectedModelByProvider.removeValue(forKey: key)
                        providerAPIKeys.removeValue(forKey: key)
                        saveProviderAPIKeys()
                        SettingsStore.shared.availableModelsByProvider = availableModelsByProvider
                        SettingsStore.shared.selectedModelByProvider = selectedModelByProvider
                        
                        // Switch to OpenAI if we just deleted the current provider
                        selectedProviderID = "openai"
                        openAIBaseURL = "https://api.openai.com/v1"
                        updateCurrentProvider()
                        availableModels = defaultModels(for: "openai")
                        selectedModel = availableModels.first ?? selectedModel
                    }) {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Delete this provider")
                }
                
                Spacer()
            }
            
            // Provider model catalogs quick links
            HStack(spacing: 6) {
                Image(systemName: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Model catalogs:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if selectedProviderID == "openai" {
                    Link("OpenAI", destination: URL(string: "https://platform.openai.com/docs/models")!)
                        .font(.caption)
                    Text("·").font(.caption).foregroundStyle(.secondary)
                    Link("Groq", destination: URL(string: "https://console.groq.com/docs/models")!)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if selectedProviderID == "groq" {
                    Link("Groq", destination: URL(string: "https://console.groq.com/docs/models")!)
                        .font(.caption)
                    Text("·").font(.caption).foregroundStyle(.secondary)
                    Link("OpenAI", destination: URL(string: "https://platform.openai.com/docs/models")!)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Link("OpenAI", destination: URL(string: "https://platform.openai.com/docs/models")!)
                        .font(.caption)
                    Text("·").font(.caption).foregroundStyle(.secondary)
                    Link("Groq", destination: URL(string: "https://console.groq.com/docs/models")!)
                        .font(.caption)
                }
            }
            .padding(.top, 2)

            HStack(spacing: 8) {
                Button(action: {
                    newProviderApiKey = providerAPIKeys[currentProvider] ?? ""
                    showAPIKeyEditor = true
                }) {
                    Label("Add or Modify API Key", systemImage: "key.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                }
                .buttonStyle(GlassButtonStyle())
                .buttonHoverEffect()



                Spacer(minLength: 8)

                // Connection Test Button
                Button(action: {
                    DebugLogger.shared.info("=== TEST CONNECTION BUTTON PRESSED ===", source: "ContentView")
                    Task { await testAPIConnection() }
                }) {
                    HStack(spacing: 4) {
                        if isTestingConnection {
                            ProgressView()
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "network")
                                .font(.caption)
                        }
                        Text(isTestingConnection ? "Testing..." : "Test")
                            .font(.caption)
                    }
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(isTestingConnection || 
                         (!isLocalEndpoint(openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) && 
                          (providerAPIKeys[currentProvider] ?? "").isEmpty))
                .buttonHoverEffect()

                Text("(\(currentProvider.capitalized))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            .sheet(isPresented: $showAPIKeyEditor) {
                VStack(spacing: 16) {
                    Text("Enter \(currentProvider.capitalized) API Key")
                        .font(.headline)

                    SecureField("API Key (optional for local endpoints)", text: $newProviderApiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)

                    HStack(spacing: 12) {
                        Button("Cancel") {
                            showAPIKeyEditor = false
                        }
                        .buttonStyle(.bordered)

                        Button("OK") {
                            let trimmedKey = newProviderApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            providerAPIKeys[currentProvider] = trimmedKey
                            saveProviderAPIKeys()
                            if connectionStatus != .unknown {
                                connectionStatus = .unknown
                                connectionErrorMessage = ""
                            }
                            showAPIKeyEditor = false
                        }
                        .buttonStyle(.borderedProminent)
                        // Allow empty API key for local endpoints
                        .disabled(!isLocalEndpoint(openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) && 
                                 newProviderApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding()
                .frame(minWidth: 350, minHeight: 150)
            }

            // Connection Status Display
            HStack(spacing: 8) {
                // Real-time validation indicator
                // Only show API key warning for non-local endpoints
                if (providerAPIKeys[currentProvider] ?? "").isEmpty && 
                   !isLocalEndpoint(openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("API key required")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if connectionStatus == .success {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text("Ready to test")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if connectionStatus == .failed {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connection failed")
                            .font(.caption)
                            .foregroundStyle(.red)
                        if !connectionErrorMessage.isEmpty {
                            Text(connectionErrorMessage)
                                .font(.caption2)
                                .foregroundStyle(.red.opacity(0.8))
                                .lineLimit(1)
                        }
                    }
                } else if connectionStatus == .testing {
                    ProgressView()
                        .frame(width: 16, height: 16)
                    Text("Testing...")
                        .font(.caption)
                        .foregroundStyle(.blue)
                } else {
                    Image(systemName: "network")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Text("Test connection to verify setup")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.top, 6)

            // Show Base URL only for custom providers (not built-in ones)
            if !["openai", "groq"].contains(selectedProviderID) {
                HStack(spacing: 8) {
                    TextField("Base URL (e.g., http://localhost:11434/v1)", text: $openAIBaseURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 350)
                        .layoutPriority(1)
                        .onChange(of: openAIBaseURL) { _ in
                            updateCurrentProvider()
                        }
                }
            }
            
            // Add Provider Modal
            if showingSaveProvider {
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        TextField("Provider name (e.g., Local Ollama)", text: $newProviderName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 250)
                        TextField("Base URL (e.g., http://localhost:11434/v1)", text: $newProviderBaseURL)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 300)
                    }

                    HStack(spacing: 8) {
                        SecureField("API Key (optional for local)", text: $newProviderApiKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 300)
                        TextField("Available models (comma-separated)", text: $newProviderModels)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 300)
                    }

                    Text("Example: llama-3.1-8b, codellama-13b, mistral-7b")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Button("Save Provider") {
                            let name = newProviderName.trimmingCharacters(in: .whitespacesAndNewlines)
                            let base = newProviderBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                            let api  = newProviderApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !name.isEmpty, !base.isEmpty, !api.isEmpty else { return }

                            let modelsList = newProviderModels
                                .split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty }
                            let models = modelsList.isEmpty ? defaultModels(for: "openai") : modelsList

                            let newProvider = SettingsStore.SavedProvider(
                                name: name,
                                baseURL: base,
                                apiKey: api,
                                models: models
                            )

                            // upsert by name
                            savedProviders.removeAll { $0.name.lowercased() == name.lowercased() }
                            savedProviders.append(newProvider)
                            saveSavedProviders()

                            // bind API key and models to canonical key
                            let key = providerKey(for: newProvider.id)
                            providerAPIKeys[key] = api
                            availableModelsByProvider[key] = models
                            selectedModelByProvider[key] = models.first ?? selectedModel
                            SettingsStore.shared.providerAPIKeys = providerAPIKeys
                            SettingsStore.shared.availableModelsByProvider = availableModelsByProvider
                            SettingsStore.shared.selectedModelByProvider = selectedModelByProvider

                            // switch selection to the new provider
                            selectedProviderID = newProvider.id
                            openAIBaseURL = base
                            updateCurrentProvider()
                            availableModels = models
                            selectedModel = models.first ?? selectedModel

                            showingSaveProvider = false
                            newProviderName = ""; newProviderBaseURL = ""; newProviderApiKey = ""; newProviderModels = ""
                        }
                        .buttonStyle(GlassButtonStyle())
                        .buttonHoverEffect()
                        .disabled({
                            let nameEmpty = newProviderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            let urlEmpty = newProviderBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            let apiKeyEmpty = newProviderApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            let isLocal = isLocalEndpoint(newProviderBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
                            
                            // Name and URL are always required
                            // API key is only required for non-local endpoints
                            return nameEmpty || urlEmpty || (!isLocal && apiKeyEmpty)
                        }())

                        Button("Cancel") {
                            showingSaveProvider = false
                            newProviderName = ""; newProviderBaseURL = ""; newProviderApiKey = ""; newProviderModels = ""
                        }
                        .buttonStyle(GlassButtonStyle())
                        .buttonHoverEffect()
                    }
                }
                .transition(.opacity)
            }

                }
                .padding(20)
            }
            .modifier(CardAppearAnimation(delay: 0.1, appear: $appear))

            // Model Configuration Section
            HoverableGlossyCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "brain.head.profile")
                            .font(.title3)
                            .foregroundStyle(.purple)
                        Text("Model Configuration")
                            .font(.headline)
                            .fontWeight(.semibold)
                    }

                    // Model Selection with Validation
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Text("Model:")
                            if availableModels.isEmpty {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .font(.caption)
                            } else if !availableModels.isEmpty && availableModels.contains(selectedModel) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                            }
                        }
                        Menu {
                            ForEach(availableModels, id: \.self) { model in
                                Button(action: {
                                    selectedModel = model
                                }) {
                                    HStack {
                                        Text(model)
                                        Spacer()
                                        if selectedModel == model {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.blue)
                                        }
                                    }
                                }
                            }
                            
                            Divider()
                            
                            Button("Add Model...") {
                                showingAddModel = true
                                newModelName = ""
                            }
                        } label: {
                            HStack {
                                Text(selectedModel)
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary)
                            .cornerRadius(6)
                        }
                        .frame(width: 220, alignment: .leading)
                        .layoutPriority(1)
            }
            
            // Add Model Input (shown when plus button is clicked)
            if showingAddModel {
                HStack(spacing: 8) {
                    TextField("Enter model name (e.g., gpt-4.1-nano)", text: $newModelName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 250)
                        .layoutPriority(1)
                    
                    Button("Add") {
                        if !newModelName.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                            let modelName = newModelName.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                            // Append to current provider's list only
                            let key = providerKey(for: selectedProviderID)
                            var list = availableModelsByProvider[key] ?? availableModels
                            if !list.contains(modelName) { list.append(modelName) }
                            availableModelsByProvider[key] = list
                            SettingsStore.shared.availableModelsByProvider = availableModelsByProvider
                            // Reflect in UI list
                            availableModels = list
                            selectedModel = modelName
                            selectedModelByProvider[key] = modelName
                            SettingsStore.shared.selectedModelByProvider = selectedModelByProvider
                            showingAddModel = false
                            newModelName = ""
                        }
                    }
                    .buttonStyle(GlassButtonStyle())
                    .buttonHoverEffect()
                .buttonHoverEffect()
                    .disabled(newModelName.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty)
                    
                    Button("Cancel") {
                        showingAddModel = false
                        newModelName = ""
                    }
                    .buttonStyle(GlassButtonStyle())
                    .buttonHoverEffect()
                .buttonHoverEffect()
                }
                .transition(.opacity)
            }

            // Manage Models List
            VStack(alignment: .leading, spacing: 8) {
                Text("Models for this provider")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(availableModels, id: \.self) { model in
                    HStack {
                        Text(model)
                        Spacer()
                        if isCustomModel(model) {
                            Button(action: { removeModel(model) }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                HStack {
                    Button("Reset to defaults") {
                        // Clear stored list for this provider and show defaults
                        availableModelsByProvider[currentProvider] = []
                        SettingsStore.shared.availableModelsByProvider = availableModelsByProvider
                        availableModels = defaultModels(for: providerKey(for: selectedProviderID))
                        selectedModel = availableModels.first ?? selectedModel
                        selectedModelByProvider[currentProvider] = selectedModel
                        SettingsStore.shared.selectedModelByProvider = selectedModelByProvider
                    }
                    .buttonStyle(GlassButtonStyle())
                    .buttonHoverEffect()
                }
            }

                }
                .padding(20)
            }
            .modifier(CardAppearAnimation(delay: 0.2, appear: $appear))



            Spacer()
        }
        .padding(20)
        .onAppear {
            // Establish provider context first
            updateCurrentProvider()

            enableAIProcessing = SettingsStore.shared.enableAIProcessing
            enableDebugLogs = SettingsStore.shared.enableDebugLogs
            availableModelsByProvider = SettingsStore.shared.availableModelsByProvider
            selectedModelByProvider = SettingsStore.shared.selectedModelByProvider
            providerAPIKeys = SettingsStore.shared.providerAPIKeys
            savedProviders = SettingsStore.shared.savedProviders

            // Migration & cleanup: normalize provider keys and drop legacy flat lists
            var normalized: [String: [String]] = [:]
            for (key, models) in availableModelsByProvider {
                let lower = key.lowercased()
                let newKey: String
                if lower == "openai" || lower == "groq" { newKey = lower }
                else { newKey = key.hasPrefix("custom:") ? key : "custom:\\(key)" }
                // Keep only unique, trimmed models
                let clean = Array(Set(models.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })).sorted()
                if !clean.isEmpty { normalized[newKey] = clean }
            }
            availableModelsByProvider = normalized
            SettingsStore.shared.availableModelsByProvider = normalized

            // Normalize selectedModelByProvider keys similarly and drop invalid selections
            var normalizedSel: [String: String] = [:]
            for (key, model) in selectedModelByProvider {
                let lower = key.lowercased()
                let newKey: String = (lower == "openai" || lower == "groq") ? lower : (key.hasPrefix("custom:") ? key : "custom:\\(key)")
                if let list = normalized[newKey], list.contains(model) { normalizedSel[newKey] = model }
            }
            selectedModelByProvider = normalizedSel
            SettingsStore.shared.selectedModelByProvider = normalizedSel

            // Determine initial model list without legacy flat-list fallback
            if let saved = savedProviders.first(where: { $0.id == selectedProviderID }) {
                // Use models from saved provider
                availableModels = saved.models
                openAIBaseURL = saved.baseURL
                providerAPIKeys[currentProvider] = saved.apiKey
            } else if let stored = availableModelsByProvider[currentProvider], !stored.isEmpty {
                // Use provider-specific stored list if present
                availableModels = stored
            } else {
                // Built-in defaults
                availableModels = defaultModels(for: providerKey(for: selectedProviderID))
            }

            // Restore previously selected model if valid
            if let sel = selectedModelByProvider[currentProvider], availableModels.contains(sel) {
                selectedModel = sel
            } else if let first = availableModels.first {
                selectedModel = first
            }
        }
        .onChange(of: asr.isRunning) { newValue in
            // Mark playground as used when user starts recording
            if newValue && !playgroundUsed {
                playgroundUsed = true
            }
        }
        .onChange(of: asr.finalText) { newValue in
            // Also mark as used when text appears in playground
            if !newValue.isEmpty && !playgroundUsed {
                playgroundUsed = true
            }
        }
        .onChange(of: enableAIProcessing) { newValue in
            SettingsStore.shared.enableAIProcessing = newValue
            // Sync to menu bar immediately
            menuBarManager.aiProcessingEnabled = newValue
        }
        .onChange(of: selectedModel) { newValue in
            if newValue != "__ADD_MODEL__" {
                selectedModelByProvider[currentProvider] = newValue
                SettingsStore.shared.selectedModelByProvider = selectedModelByProvider
            }
        }
    }

    // MARK: - Meeting Transcription (Coming Soon)
    private var meetingToolsView: some View
    {
        MeetingTranscriptionView()
    }

    // MARK: - Feedback View
    private var feedbackView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "envelope.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading) {
                            Text("Send Feedback")
                                .font(.system(size: 28, weight: .bold))
                            Text("Help us improve FluidVoice")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.bottom, 8)

                // Feedback Form
                HoverableGlossyCard {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Email")
                                .font(.headline)
                                .fontWeight(.semibold)

                            TextField("your.email@example.com", text: $feedbackEmail)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 14))

                            Text("Feedback")
                                .font(.headline)
                                .fontWeight(.semibold)
                                .padding(.top, 8)

                            TextEditor(text: $feedbackText)
                                .font(.system(size: 14))
                                .frame(height: 120)
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.gray.opacity(0.1))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                        )
                                )
                                .overlay(
                                    VStack {
                                        if feedbackText.isEmpty {
                                            Text("Share your thoughts, report bugs, or suggest features...")
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .allowsHitTesting(false)
                                )

                            // Debug logs option
                            Toggle("Include debug logs", isOn: $includeDebugLogs)
                                .toggleStyle(GlassToggleStyle())

                            // Send Button
                            HStack {
                                Spacer()
                                
                                Button(action: {
                                    Task {
                                        await sendFeedback()
                                    }
                                }) {
                                    HStack(spacing: 8) {
                                        if isSendingFeedback {
                                            ProgressView()
                                                .scaleEffect(0.8)
                                        } else {
                                            Image(systemName: "paperplane.fill")
                                        }
                                        Text(isSendingFeedback ? "Sending..." : "Send Feedback")
                                            .fontWeight(.semibold)
                                    }
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                                }
                                .buttonStyle(GlassButtonStyle())
                                .disabled(feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || 
                                         feedbackEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                         isSendingFeedback)
                                .buttonHoverEffect()
                            }
                        }
                    }
                    .padding(20)
                }
                .modifier(CardAppearAnimation(delay: 0.1, appear: $appear))
            }
            .padding(24)
        }
        .alert("Feedback Sent", isPresented: $showFeedbackConfirmation) {
            Button("OK") { }
        } message: {
            Text("Thank you for helping us improve FluidVoice.")
        }
    }

    // MARK: - Audio Tab
    private var audioView: some View
    {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Input Device")
                Spacer()
                Picker("Input Device", selection: $selectedInputUID) {
                    ForEach(inputDevices, id: \.uid) { dev in
                        Text(dev.name).tag(dev.uid)
                    }
                }
                .frame(width: 280)
                .onChange(of: selectedInputUID) { newUID in
                    SettingsStore.shared.preferredInputDeviceUID = newUID
                    _ = AudioDevice.setDefaultInputDevice(uid: newUID)
                    if asr.isRunning {
                        asr.stopWithoutTranscription()
                        startRecording()
                    }
                }
            }

            HStack {
                Text("Output Device")
                Spacer()
                Picker("Output Device", selection: $selectedOutputUID) {
                    ForEach(outputDevices, id: \.uid) { dev in
                        Text(dev.name).tag(dev.uid)
                    }
                }
                .frame(width: 280)
                .onChange(of: selectedOutputUID) { newUID in
                    SettingsStore.shared.preferredOutputDeviceUID = newUID
                    _ = AudioDevice.setDefaultOutputDevice(uid: newUID)
                }
            }

            HStack(spacing: 12) {
                Button {
                    refreshDevices()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

                if let defIn = AudioDevice.getDefaultInputDevice()?.name, let defOut = AudioDevice.getDefaultOutputDevice()?.name {
                    Text("Default In: \(defIn) · Default Out: \(defOut)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Visualization Sensitivity Section
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Visualization Sensitivity")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Control how sensitive the audio visualizer is to sound input")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Button("Reset") {
                        visualizerNoiseThreshold = 0.4
                        SettingsStore.shared.visualizerNoiseThreshold = visualizerNoiseThreshold
                    }
                    .font(.system(size: 12))
                }
                
                HStack(spacing: 12) {
                    Text("More Sensitive")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 70)
                    
                    Slider(value: $visualizerNoiseThreshold, in: 0.01...0.8, step: 0.01)
                        .controlSize(.regular)
                    
                    Text("Less Sensitive")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 70)
                    
                    Text(String(format: "%.2f", visualizerNoiseThreshold))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.primary)
                        .frame(width: 40)
                }
            }
            .padding(20)
            
            // Removed Debug Settings section

            Spacer()
        }
        .padding(20)
        .onAppear { refreshDevices() }
        .onChange(of: visualizerNoiseThreshold) { newValue in
            SettingsStore.shared.visualizerNoiseThreshold = newValue
        }
    }

    private func refreshDevices()
    {
        inputDevices = AudioDevice.listInputDevices()
        outputDevices = AudioDevice.listOutputDevices()
    }

    // MARK: - Model Management Functions
    private func saveModels() { SettingsStore.shared.availableModels = availableModels }
    
    // MARK: - Provider Management Functions
    private func providerKey(for providerID: String) -> String {
        if providerID == "openai" || providerID == "groq" { return providerID }
        // Saved providers use their stable id
        return providerID.isEmpty ? currentProvider : "custom:\\(providerID)"
    }

    private func defaultModels(for providerKey: String) -> [String] {
        switch providerKey {
        case "openai": return ["gpt-4.1"]
        case "groq": return ["openai/gpt-oss-120b"]
        default: return []
        }
    }

    private func saveProviderAPIKeys() {
        SettingsStore.shared.providerAPIKeys = providerAPIKeys
    }
    
    private func updateCurrentProvider() {
        // Map baseURL to canonical key for built-ins; else keep existing
        let url = openAIBaseURL.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if url.contains("openai.com") { currentProvider = "openai"; return }
        if url.contains("groq.com") { currentProvider = "groq"; return }
        // For saved/custom, keep current or derive from selectedProviderID
        currentProvider = providerKey(for: selectedProviderID)
    }
    
    private func saveSavedProviders() {
        SettingsStore.shared.savedProviders = savedProviders
    }

    // MARK: - App Detection and Context-Aware Prompts
    private func getCurrentAppInfo() -> (name: String, bundleId: String, windowTitle: String) {
        if let frontmostApp = NSWorkspace.shared.frontmostApplication {
            let name = frontmostApp.localizedName ?? "Unknown"
            let bundleId = frontmostApp.bundleIdentifier ?? "unknown"
            let title = self.getFrontmostWindowTitle(ownerPid: frontmostApp.processIdentifier) ?? ""
            return (name: name, bundleId: bundleId, windowTitle: title)
        }
        return (name: "Unknown", bundleId: "unknown", windowTitle: "")
    }

    /// Best-effort frontmost window title lookup for the current app
    private func getFrontmostWindowTitle(ownerPid: pid_t) -> String? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in windowInfo {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid == ownerPid else { continue }
            if let name = info[kCGWindowName as String] as? String, name.isEmpty == false {
                return name
            }
        }
        return nil
    }
    
    private func getContextualPrompt(for appInfo: (name: String, bundleId: String, windowTitle: String)) -> String {
        let appName = appInfo.name
        let bundleId = appInfo.bundleId.lowercased()
        let windowTitle = appInfo.windowTitle.lowercased()
        
        // Code editors and IDEs
        if bundleId.contains("xcode") || bundleId.contains("vscode") || bundleId.contains("sublime") || 
           bundleId.contains("atom") || bundleId.contains("jetbrains") || bundleId.contains("cursor") ||
           bundleId.contains("vim") || bundleId.contains("emacs") || appName.lowercased().contains("code")
        {
            return "Clean up this transcribed text for code editor \(appName). Make the smallest necessary mechanical edits; do not add or invent content or answer questions. Remove fillers and false starts. Correct programming terms and obvious transcription errors. Preserve meaning and tone."
        }
        
        // Email applications
        else if bundleId.contains("mail") || bundleId.contains("outlook") || bundleId.contains("thunderbird") || 
                bundleId.contains("airmail") || bundleId.contains("spark")
        {
            return "Clean up this transcribed text for email app \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix grammar, punctuation, and capitalization while preserving meaning and tone."
        }
        
        // Messaging and chat applications
        else if bundleId.contains("messages") || bundleId.contains("slack") || bundleId.contains("discord") || 
                bundleId.contains("telegram") || bundleId.contains("whatsapp") || bundleId.contains("signal") ||
                bundleId.contains("teams") || bundleId.contains("zoom")
        {
            return "Clean up this transcribed text for messaging app \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix basic grammar and clarity while keeping the casual tone."
        }
        
        // Document editors and word processors
        else if bundleId.contains("pages") || bundleId.contains("word") || bundleId.contains("docs") || 
                bundleId.contains("writer") || bundleId.contains("notion") || bundleId.contains("bear") ||
                bundleId.contains("ulysses") || bundleId.contains("scrivener")
        {
            return "Clean up this transcribed text for document editor \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix grammar, punctuation, and structure while preserving meaning."
        }
        
        // Note-taking applications
        else if bundleId.contains("notes") || bundleId.contains("obsidian") || bundleId.contains("roam") || 
                bundleId.contains("logseq") || bundleId.contains("evernote") || bundleId.contains("onenote")
        {
            return "Clean up this transcribed text for note-taking app \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix grammar and organize into clear, readable notes without adding information."
        }
        
        // Browsers (various web apps). Include: Safari, Chrome, Firefox, Edge, Arc, Brave, Dia, Comet
        else if bundleId.contains("safari") || bundleId.contains("chrome") || bundleId.contains("firefox") || 
                bundleId.contains("edge") || bundleId.contains("arc") || bundleId.contains("brave") ||
                bundleId.contains("dia") || bundleId.contains("comet") ||
                appName.lowercased().contains("safari") || appName.lowercased().contains("chrome") ||
                appName.lowercased().contains("arc") || appName.lowercased().contains("brave") ||
                appName.lowercased().contains("dia") || appName.lowercased().contains("comet")
        {
            // Infer common web apps from window title for better context
            if let inferred = inferWebContext(from: windowTitle, appName: appName) {
                return inferred
            }
            return "Clean up this transcribed text for web browser \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix grammar and basic formatting while preserving meaning."
        }
        
        // Terminal and command line tools
        else if bundleId.contains("terminal") || bundleId.contains("iterm") || bundleId.contains("console") ||
                appName.lowercased().contains("terminal")
        {
            return "Clean up this transcribed text for terminal \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix command syntax, file paths, and technical terms without adding options or commands."
        }
        
        // Social media and creative apps
        else if bundleId.contains("twitter") || bundleId.contains("facebook") || bundleId.contains("instagram") ||
                bundleId.contains("tiktok") || bundleId.contains("linkedin")
        {
            return "Clean up this transcribed text for social media app \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix basic grammar while keeping the natural, engaging tone."
        }
        
        // Default fallback
        else
        {
            return "Clean up this transcribed text for \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix grammar, punctuation, and formatting while preserving meaning and tone."
        }
    }

    /// Infer web-app specific prompt from a browser window title
    private func inferWebContext(from windowTitle: String, appName: String) -> String? {
        let title = windowTitle
        // Email (Gmail, Outlook Web)
        if title.contains("gmail") || title.contains("inbox") || title.contains("outlook") {
            return "Clean up this transcribed text for email app \(appName) (web). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix grammar, punctuation, and capitalization while preserving meaning."
        }
        // Messaging (Slack, Discord, Teams, Telegram, WhatsApp)
        if title.contains("slack") || title.contains("discord") || title.contains("teams") || title.contains("telegram") || title.contains("whatsapp") {
            return "Clean up this transcribed text for messaging app \(appName) (web). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix basic grammar and clarity while keeping the casual tone."
        }
        // Documents (Google Docs/Sheets, Notion, Confluence)
        if title.contains("google docs") || title.contains("docs") || title.contains("notion") || title.contains("confluence") || title.contains("google sheets") || title.contains("sheet") {
            return "Clean up this transcribed text for a document editor in \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Improve grammar, structure, and readability without adding information."
        }
        // Code (GitHub, Stack Overflow, online IDEs)
        if title.contains("github") || title.contains("stack overflow") || title.contains("stackexchange") || title.contains("replit") || title.contains("codesandbox") {
            return "Clean up this transcribed text for code-related context in \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Correct programming terms and obvious errors without adding explanations."
        }
        // Project/issue tracking (Jira, Linear, Asana)
        if title.contains("jira") || title.contains("linear") || title.contains("asana") || title.contains("clickup") {
            return "Clean up this transcribed text for project management context in \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Keep the text concise and clear without adding commentary."
        }
        return nil
    }

    /// Build a base system prompt and append contextual addendum
    private func buildSystemPrompt(appInfo: (name: String, bundleId: String, windowTitle: String)) -> String {
        let base = """
        You are a transcription post-processor. Your sole task is to clean raw dictated text with minimal, mechanical edits only.
        - Make the smallest necessary edits. If the text is already clear and grammatical, return it unchanged.
        - Do not add, invent, or infer any content not present in the input. Never answer questions or provide suggestions.
        - Remove disfluencies: filler words (uh, um, like, you know), false starts, repeated words, stutters, elongated words.
        - Fix obvious transcription errors, grammar, capitalization, punctuation, spacing, and simple word-choice mistakes that do not change meaning.
        - Maintain the original tone and structure. Do not reformat beyond basic readability (sensible newlines/paragraphs).
        - Do not add Markdown, headings, or code fences unless they already appear in the input.
        - If the text is a question, preserve it as a question. Do NOT answer it.
        - If any rule conflicts, prefer fewer edits and no new content.
        - Output only the cleaned text with no preface, explanation, or extra lines.

        Examples (do not include the labels):
        Input: "uh can you, um, email John later question mark"
        Output: "Can you email John later?"

        Input: "What's the time in Tokyo?"
        Output: "What's the time in Tokyo?"  // do not answer

        Input: "The function returns an arr a y of ints"
        Output: "The function returns an array of ints"
        """
        let addendum = getContextualPrompt(for: appInfo)
        var context = "Context:\n- Active app: \(appInfo.name) (\(appInfo.bundleId))"
        if appInfo.windowTitle.isEmpty == false {
            context += "\n- Active window title: \(appInfo.windowTitle)"
        }
        return base + "\n\n" + addendum + "\n\n" + context
    }
    
    // MARK: - Local Endpoint Detection
    private func isLocalEndpoint(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let host = url.host else { return false }
        
        let hostLower = host.lowercased()
        
        // Check for localhost variations
        if hostLower == "localhost" || hostLower == "127.0.0.1" {
            return true
        }
        
        // Check for private IP ranges
        // 127.x.x.x
        if hostLower.hasPrefix("127.") {
            return true
        }
        // 10.x.x.x
        if hostLower.hasPrefix("10.") {
            return true
        }
        // 192.168.x.x
        if hostLower.hasPrefix("192.168.") {
            return true
        }
        // 172.16.x.x - 172.31.x.x
        if hostLower.hasPrefix("172.") {
            let components = hostLower.split(separator: ".")
            if components.count >= 2,
               let secondOctet = Int(components[1]),
               secondOctet >= 16 && secondOctet <= 31 {
                return true
            }
        }
        
        return false
    }

    // MARK: - Modular AI Processing
    private func processTextWithAI(_ inputText: String) async -> String {
        let endpoint = openAIBaseURL.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty ? "https://api.openai.com/v1" : openAIBaseURL.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        
        // Build the full URL - only append /chat/completions if not already present
        let fullEndpoint: String
        if endpoint.contains("/chat/completions") || 
           endpoint.contains("/api/chat") || 
           endpoint.contains("/api/generate") {
            // URL already has a complete path, use as-is
            fullEndpoint = endpoint
        } else {
            // Append /chat/completions for OpenAI-compatible endpoints
            fullEndpoint = endpoint + "/chat/completions"
        }
        
        guard let url = URL(string: fullEndpoint) else {
            return "Error: Invalid Base URL"
        }
        
        let isLocal = isLocalEndpoint(endpoint)
        let apiKey = providerAPIKeys[currentProvider] ?? ""
        
        // Skip API key validation for local endpoints
        if !isLocal {
            guard !apiKey.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
                return "Error: API Key not set for \(currentProvider)"
            }
        }

        struct ChatMessage: Codable { let role: String; let content: String }
        struct ChatRequest: Codable { let model: String; let messages: [ChatMessage]; let temperature: Double? }
        struct ChatChoiceMessage: Codable { let role: String; let content: String }
        struct ChatChoice: Codable { let index: Int?; let message: ChatChoiceMessage }
        struct ChatResponse: Codable { let choices: [ChatChoice] }

        // Get app context captured at start of recording if available
        let appInfo = recordingAppInfo ?? getCurrentAppInfo()
        let systemPrompt = buildSystemPrompt(appInfo: appInfo)
        DebugLogger.shared.debug("Using app context for AI: app=\(appInfo.name), bundleId=\(appInfo.bundleId), title=\(appInfo.windowTitle)", source: "ContentView")
        
        let body = ChatRequest(
            model: selectedModel,
            messages: [
                ChatMessage(role: "system", content: systemPrompt),
                ChatMessage(role: "user", content: inputText)
            ],
            temperature: 0.2
        )

        guard let jsonData = try? JSONEncoder().encode(body) else {
            return "Error: Failed to encode request"
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Only add Authorization header for non-local endpoints
        if !isLocal {
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        request.httpBody = jsonData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            // Debug: Print raw response
            print("=== OLLAMA RESPONSE DEBUG (ContentView) ===")
            print("Response URL: \(request.url?.absoluteString ?? "unknown")")
            if let http = response as? HTTPURLResponse {
                print("HTTP Status: \(http.statusCode)")
            }
            if let responseText = String(data: data, encoding: .utf8) {
                print("Raw Response: \(responseText)")
            }
            print("==========================================")
            
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                let errText = String(data: data, encoding: .utf8) ?? "Unknown error"
                return "Error: HTTP \(http.statusCode): \(errText)"
            }
            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            return decoded.choices.first?.message.content ?? "<no content>"
        } catch {
            print("=== OLLAMA DECODE ERROR (ContentView) ===")
            print("Error: \(error)")
            if let decodingError = error as? DecodingError {
                print("Decoding Error Details: \(decodingError)")
            }
            print("========================================")
            return "Error: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Stop and Process Transcription
    private func stopAndProcessTranscription() async {
        DebugLogger.shared.debug("stopAndProcessTranscription called", source: "ContentView")

        // Stop the ASR service and wait for transcription to complete
        let transcribedText = await asr.stop()

        guard transcribedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            DebugLogger.shared.debug("Transcription returned empty text", source: "ContentView")
            return
        }

        let finalText: String

        // Check if we should use AI processing
        let apiKey = (providerAPIKeys[currentProvider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let isLocal = isLocalEndpoint(baseURL)
        let shouldUseAI = enableAIProcessing && (isLocal || !apiKey.isEmpty)
        
        if shouldUseAI {
            DebugLogger.shared.debug("Routing transcription through AI post-processing", source: "ContentView")
            finalText = await processTextWithAI(transcribedText)
        } else {
            finalText = transcribedText
        }

        DebugLogger.shared.info("Transcription finalized (chars: \(finalText.count))", source: "ContentView")

        await MainActor.run {
            let frontmostApp = NSWorkspace.shared.frontmostApplication
            let frontmostName = frontmostApp?.localizedName ?? "Unknown"
            let isFluidFrontmost = frontmostApp?.bundleIdentifier?.contains("fluid") == true
            let shouldTypeExternally = !isFluidFrontmost || isTranscriptionFocused == false

            DebugLogger.shared.debug(
                "Typing decision → frontmost: \(frontmostName), fluidFrontmost: \(isFluidFrontmost), editorFocused: \(isTranscriptionFocused), willTypeExternally: \(shouldTypeExternally)",
                source: "ContentView"
            )

            if shouldTypeExternally {
                asr.typeTextToActiveField(finalText)
            }
        }
    }

    // Capture app context at start to avoid mismatches if the user switches apps mid-session
    private func startRecording() {
        let info = getCurrentAppInfo()
        recordingAppInfo = info
        DebugLogger.shared.debug("Captured recording app context: app=\(info.name), bundleId=\(info.bundleId), title=\(info.windowTitle)", source: "ContentView")
        asr.start()
    }
    
    // MARK: - ASR Model Preloading
    private func preloadASRModel() async {
        DebugLogger.shared.debug("Starting ASR model preload on app startup", source: "ContentView")
        // Call the ASR service directly to preload the model
        await MainActor.run {
            asr.isDownloadingModel = true
        }
        
        do {
            try await asr.ensureAsrReady()
            DebugLogger.shared.info("ASR model preload completed successfully", source: "ContentView")
        } catch {
            DebugLogger.shared.error("ASR model preload failed: \(error.localizedDescription)", source: "ContentView")
        }
        
        await MainActor.run {
            asr.isDownloadingModel = false
        }
    }
    
    // MARK: - API Connection Testing
    private func testAPIConnection() async {
        guard !isTestingConnection else { return }

        let apiKey = providerAPIKeys[currentProvider] ?? ""
        let baseURL = openAIBaseURL.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let isLocal = isLocalEndpoint(baseURL)

        // Debug logging
        DebugLogger.shared.info("API connection test started (provider: \(currentProvider), baseURL: \(baseURL), isLocal: \(isLocal))", source: "ContentView")
        DebugLogger.shared.debug("API key supplied: \(!apiKey.isEmpty), length: \(apiKey.count)", source: "ContentView")

        // Only validate API key for non-local endpoints
        if !isLocal {
            if !apiKey.hasPrefix("sk-") {
                DebugLogger.shared.warning("PROBLEM: API key doesn't start with 'sk-' - this is likely the cause of the 401 error!", source: "ContentView")
            }
            if apiKey.count < 20 || apiKey.count > 200 {
                DebugLogger.shared.warning("PROBLEM: API key length is unusual - should be 20-200 characters!", source: "ContentView")
            }
        }

        // For local endpoints, only baseURL is required
        if isLocal {
            guard !baseURL.isEmpty else {
                DebugLogger.shared.error("Missing required field - base URL is empty", source: "ContentView")
                await MainActor.run {
                    connectionStatus = .failed
                    connectionErrorMessage = "Base URL is required"
                }
                return
            }
        } else {
            // For remote endpoints, both API key and baseURL are required
            guard !apiKey.isEmpty && !baseURL.isEmpty else {
                DebugLogger.shared.error("Missing required fields - API key or base URL is empty", source: "ContentView")
                await MainActor.run {
                    connectionStatus = .failed
                    connectionErrorMessage = "API key and base URL are required"
                }
                return
            }
        }

        await MainActor.run {
            isTestingConnection = true
            connectionStatus = .testing
            connectionErrorMessage = ""
        }

        do {
            let endpoint = baseURL.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            
            // Build the full URL - only append /chat/completions if not already present
            let fullURL: String
            if endpoint.contains("/chat/completions") || 
               endpoint.contains("/api/chat") || 
               endpoint.contains("/api/generate") {
                // URL already has a complete path, use as-is
                fullURL = endpoint
            } else {
                // Append /chat/completions for OpenAI-compatible endpoints
                fullURL = endpoint + "/chat/completions"
            }
            
            DebugLogger.shared.debug("Full endpoint URL: \(fullURL)", source: "ContentView")

            guard let url = URL(string: fullURL) else {
                DebugLogger.shared.error("Failed to create URL from: \(fullURL)", source: "ContentView")
                await MainActor.run {
                    connectionStatus = .failed
                    connectionErrorMessage = "Invalid Base URL format"
                }
                return
            }

            DebugLogger.shared.debug("Successfully created URL: \(url.absoluteString)", source: "ContentView")

            // Use the exact same format as the real API calls
            struct TestChatMessage: Codable {
                let role: String
                let content: String
            }

            struct TestChatRequest: Codable {
                let model: String
                let messages: [TestChatMessage]
                let max_tokens: Int
            }

            let testBody = TestChatRequest(
                model: selectedModel, // Use the selected model from the UI
                messages: [TestChatMessage(role: "user", content: "test")],
                max_tokens: 1 // Minimal response to save tokens
            )

            print("Using model for test: \(selectedModel)")

            guard let jsonData = try? JSONEncoder().encode(testBody) else {
                print("[DEBUG] Failed to encode test request body")
                await MainActor.run {
                    connectionStatus = .failed
                    connectionErrorMessage = "Failed to encode test request"
                }
                return
            }

            // Create request with proper logging
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            // Only add Authorization header for non-local endpoints
            if !isLocal {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            
            request.httpBody = jsonData

            // Log request details (mask API key for security)
            let maskedKey = apiKey.count > 8 ? "\(apiKey.prefix(4))****\(apiKey.suffix(4))" : "****"
            print("[DEBUG] Request details:")
            print("[DEBUG]   Method: \(request.httpMethod ?? "Unknown")")
            print("[DEBUG]   URL: \(request.url?.absoluteString ?? "Unknown")")
            print("[DEBUG]   Content-Type: \(request.value(forHTTPHeaderField: "Content-Type") ?? "Not set")")
            if isLocal {
                print("[DEBUG]   Authorization header: Skipped (local endpoint detected)")
            } else {
                print("[DEBUG]   Authorization header: \(request.value(forHTTPHeaderField: "Authorization") != nil ? "Set (Bearer \(maskedKey))" : "NOT SET - This is likely the problem!")")
                print("[DEBUG]   Full Authorization header: \(request.value(forHTTPHeaderField: "Authorization") ?? "NOT SET")")
            }
            print("[DEBUG]   Body size: \(jsonData.count) bytes")
            if let bodyString = String(data: jsonData, encoding: .utf8) {
                print("[DEBUG]   Request body: \(bodyString)")
            }

            print("=== SENDING REQUEST ===")
            print("URL: \(request.url?.absoluteString ?? "Unknown")")
            print("Method: \(request.httpMethod ?? "Unknown")")
            print("Authorization: \(request.value(forHTTPHeaderField: "Authorization") != nil ? "Set" : "NOT SET")")

            let (_, response) = try await URLSession.shared.data(for: request)

            print("=== RECEIVED RESPONSE ===")

            if let httpResponse = response as? HTTPURLResponse {
                print("HTTP Status: \(httpResponse.statusCode)")
                print("Response headers: \(httpResponse.allHeaderFields)")

                if (200...299).contains(httpResponse.statusCode) {
                    print("SUCCESS: Connection test passed!")
                    await MainActor.run {
                        connectionStatus = .success
                        connectionErrorMessage = ""
                    }
                } else {
                    print("FAILED: HTTP \(httpResponse.statusCode)")
                    if httpResponse.statusCode == 401 {
                        print("401 Error: This usually means:")
                        print("  - API key is invalid or expired")
                        print("  - API key doesn't start with 'sk-'")
                        print("  - Insufficient credits on the account")
                        print("  - Wrong API key type (using secret key instead of API key)")
                    }
                    await MainActor.run {
                        connectionStatus = .failed
                        connectionErrorMessage = "HTTP \(httpResponse.statusCode): Invalid API key or insufficient credits"
                    }
                }
            } else {
                print("[DEBUG] Invalid response type - not HTTPURLResponse")
                await MainActor.run {
                    connectionStatus = .failed
                    connectionErrorMessage = "Invalid response from server"
                }
            }
        } catch {
            print("[DEBUG] Network error during connection test:")
            print("[DEBUG]   Error: \(error.localizedDescription)")
            print("[DEBUG]   Error type: \(type(of: error))")
            if let urlError = error as? URLError {
                print("[DEBUG]   URL Error Code: \(urlError.code.rawValue)")
                print("[DEBUG]   URL Error User Info: \(urlError.userInfo)")
            }

            await MainActor.run {
                connectionStatus = .failed
                connectionErrorMessage = error.localizedDescription
            }
        }

        await MainActor.run {
            isTestingConnection = false
            print("🏁 ===== CONNECTION TEST COMPLETE =====")
            print("🏁 Final Status: \(connectionStatus)")
            if !connectionErrorMessage.isEmpty {
                print("🏁 Error: \(connectionErrorMessage)")
            }
            print("🏁 ===== END OF TEST =====")
        }
    }

    // MARK: - OpenAI-compatible call for playground
    private func callOpenAIChat() async {
        guard !isCallingAI else { return }
        await MainActor.run { isCallingAI = true }
        defer { Task { await MainActor.run { isCallingAI = false } } }
        
        let result = await processTextWithAI(aiInputText)
        await MainActor.run { aiOutputText = result }
    }

    private func getModelStatusText() -> String {
        if asr.isDownloadingModel {
            return "Model is downloading... Please wait."
        } else if asr.isAsrReady {
            return "Model is ready to use!"
        } else {
            return "Model will auto-download when needed (or click Download Model Now)."
        }
    }
    
    private func labelFor(status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "Microphone: Authorized"
        case .denied: return "Microphone: Denied"
        case .restricted: return "Microphone: Restricted"
        case .notDetermined: return "Microphone: Not Determined"
        @unknown default: return "Microphone: Unknown"
        }
    }
    
    private func checkAccessibilityPermissions() -> Bool {
        return AXIsProcessTrusted()
    }
    
    private func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    AXIsProcessTrustedWithOptions(options)
    didOpenAccessibilityPane = true
    UserDefaults.standard.set(true, forKey: accessibilityRestartFlagKey)
    }

    private func restartApp() {
        let appPath = Bundle.main.bundlePath
        let process = Process()
        process.launchPath = "/usr/bin/open"
        process.arguments = ["-n", appPath]
        // Clear pending flag and hide prompt before restarting
        UserDefaults.standard.set(false, forKey: accessibilityRestartFlagKey)
        showRestartPrompt = false
        try? process.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.terminate(nil)
        }
    }

    private func revealAppInFinder() {
        let appPath = Bundle.main.bundlePath
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: appPath)])
    }

    private func openApplicationsFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
    }
    
    // MARK: - Feedback Functions
    private func sendFeedback() async {
        guard !feedbackEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        
        await MainActor.run {
            isSendingFeedback = true
        }
        
        let feedbackData = createFeedbackData()
        let success = await submitFeedback(data: feedbackData)
        
        await MainActor.run {
            isSendingFeedback = false
            if success {
                // Show confirmation and clear form
                showFeedbackConfirmation = true
                feedbackText = ""
                feedbackEmail = ""
                includeDebugLogs = false
            }
        }
    }
    
    private func createFeedbackData() -> [String: Any] {
        var feedbackContent = feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if includeDebugLogs {
            feedbackContent += "\n\n--- Debug Information ---\n"
            feedbackContent += "App Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")\n"
            feedbackContent += "Build: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown")\n"
            feedbackContent += "macOS Version: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
            feedbackContent += "Date: \(Date().formatted())\n\n"
            
            // Add recent log entries
            let logFileURL = FileLogger.shared.currentLogFileURL()
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                do {
                    let logContent = try String(contentsOf: logFileURL)
                    let lines = logContent.components(separatedBy: .newlines)
                    let recentLines = Array(lines.suffix(30)) // Last 30 lines
                    feedbackContent += "Recent Log Entries:\n"
                    feedbackContent += recentLines.joined(separator: "\n")
                } catch {
                    feedbackContent += "Could not read log file: \(error.localizedDescription)\n"
                }
            }
        }
        
        return [
            "email_id": feedbackEmail.trimmingCharacters(in: .whitespacesAndNewlines),
            "feedback": feedbackContent
        ]
    }
    
    private func submitFeedback(data: [String: Any]) async -> Bool {
        guard let url = URL(string: "https://altic.dev/api/fluid/feedback") else {
            DebugLogger.shared.error("Invalid feedback API URL", source: "ContentView")
            return false
        }
        
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: data)
            
            let (_, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                let success = (200...299).contains(httpResponse.statusCode)
                if success {
                    DebugLogger.shared.info("Feedback submitted successfully", source: "ContentView")
                } else {
                    DebugLogger.shared.error("Feedback submission failed with status: \(httpResponse.statusCode)", source: "ContentView")
                }
                return success
            }
            return false
        } catch {
            DebugLogger.shared.error("Network error submitting feedback: \(error.localizedDescription)", source: "ContentView")
            return false
        }
    }
    
    // MARK: - Hotkey Manager Initialization Helpers
    private func initializeHotkeyManagerIfNeeded() {
        guard hotkeyManager == nil else { return }
        
        if UserDefaults.standard.bool(forKey: "enableDebugLogs") {
            print("[ContentView] Initializing hotkey manager with accessibility enabled: \(accessibilityEnabled)")
        }
        
        hotkeyManager = GlobalHotkeyManager(asrService: asr, shortcut: hotkeyShortcut)
        hotkeyManager?.enablePressAndHoldMode(pressAndHoldModeEnabled)
        hotkeyManager?.setStopAndProcessCallback {
            await self.stopAndProcessTranscription()
        }
        
        // Monitor initialization status
        Task {
            // Give some time for initialization
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            
            await MainActor.run {
                self.hotkeyManagerInitialized = self.hotkeyManager?.validateEventTapHealth() ?? false
                if UserDefaults.standard.bool(forKey: "enableDebugLogs") {
                    print("[ContentView] Initial hotkey manager health check: \(self.hotkeyManagerInitialized)")
                }
                
                // If still not initialized and accessibility is enabled, try reinitializing
                if !self.hotkeyManagerInitialized && self.accessibilityEnabled {
                    if UserDefaults.standard.bool(forKey: "enableDebugLogs") {
                        print("[ContentView] Hotkey manager not healthy, attempting reinitalization")
                    }
                    self.hotkeyManager?.reinitialize()
                }
            }
        }
    }
    
    // MARK: - Model Management Helpers
    
    private func isCustomModel(_ model: String) -> Bool {
        // Non-removable defaults are the provider's default models
        return !defaultModels(for: currentProvider).contains(model)
    }
    
    private func removeModel(_ model: String) {
        // Don't remove if it's currently selected
        if selectedModel == model {
            // Switch to first available model that's not the one being removed
            if let firstOther = availableModels.first(where: { $0 != model }) {
                selectedModel = firstOther
            }
        }
        
        // Remove from current provider's model list
        availableModels.removeAll { $0 == model }
        
        // Update the stored models for this provider
        let key = providerKey(for: selectedProviderID)
        availableModelsByProvider[key] = availableModels
        SettingsStore.shared.availableModelsByProvider = availableModelsByProvider
        
        // Update selected model mapping for this provider
        selectedModelByProvider[key] = selectedModel
        SettingsStore.shared.selectedModelByProvider = selectedModelByProvider
    }
    
    // Deprecated: hotkey persistence is handled via SettingsStore
}

private enum SidebarItem: Hashable {
    case welcome
    case recording
    case aiProcessing
    case audio
    case settings
    case meetingTools
    case feedback
}

// MARK: - Embedded CoreAudio Device Manager
enum AudioDevice
{
    struct Device: Identifiable, Hashable
    {
        let id: AudioObjectID
        let uid: String
        let name: String
        let hasInput: Bool
        let hasOutput: Bool
    }

    static func listAllDevices() -> [Device]
    {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
        if status != noErr || dataSize == 0
        {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs)
        if status != noErr
        {
            return []
        }

        var devices: [Device] = []
        devices.reserveCapacity(deviceIDs.count)

        for devId in deviceIDs
        {
            let name = getStringProperty(devId, selector: kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal) ?? "Unknown"
            let uid = getStringProperty(devId, selector: kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal) ?? ""
            let hasIn = hasChannels(devId, scope: kAudioObjectPropertyScopeInput)
            let hasOut = hasChannels(devId, scope: kAudioObjectPropertyScopeOutput)
            devices.append(Device(id: devId, uid: uid, name: name, hasInput: hasIn, hasOutput: hasOut))
        }

        return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func listInputDevices() -> [Device]
    {
        return listAllDevices().filter { $0.hasInput }
    }

    static func listOutputDevices() -> [Device]
    {
        return listAllDevices().filter { $0.hasOutput }
    }

    static func getDefaultInputDevice() -> Device?
    {
        guard let devId: AudioObjectID = getDefaultDeviceId(selector: kAudioHardwarePropertyDefaultInputDevice) else { return nil }
        return listAllDevices().first { $0.id == devId }
    }

    static func getDefaultOutputDevice() -> Device?
    {
        guard let devId: AudioObjectID = getDefaultDeviceId(selector: kAudioHardwarePropertyDefaultOutputDevice) else { return nil }
        return listAllDevices().first { $0.id == devId }
    }

    @discardableResult
    static func setDefaultInputDevice(uid: String) -> Bool
    {
        guard let device = listInputDevices().first(where: { $0.uid == uid }) else { return false }
        return setDefaultDeviceId(device.id, selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    @discardableResult
    static func setDefaultOutputDevice(uid: String) -> Bool
    {
        guard let device = listOutputDevices().first(where: { $0.uid == uid }) else { return false }
        return setDefaultDeviceId(device.id, selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    private static func getDefaultDeviceId(selector: AudioObjectPropertySelector) -> AudioObjectID?
    {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devId = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devId)
        return status == noErr ? devId : nil
    }

    private static func setDefaultDeviceId(_ devId: AudioObjectID, selector: AudioObjectPropertySelector) -> Bool
    {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableDevId = devId
        let size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &mutableDevId)
        return status == noErr
    }

    private static func getStringProperty(_ devId: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> String?
    {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(devId, &address, 0, nil, &dataSize)
        if status != noErr || dataSize == 0
        {
            return nil
        }

        let rawPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<Int8>.alignment)
        defer { rawPtr.deallocate() }

        status = AudioObjectGetPropertyData(devId, &address, 0, nil, &dataSize, rawPtr)
        if status != noErr
        {
            return nil
        }

        let cfStr = rawPtr.load(as: CFString.self)
        return cfStr as String
    }

    private static func hasChannels(_ devId: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool
    {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(devId, &address, 0, nil, &dataSize)
        if status != noErr || dataSize == 0
        {
            return false
        }

        let rawPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<Int8>.alignment)
        defer { rawPtr.deallocate() }

        status = AudioObjectGetPropertyData(devId, &address, 0, nil, &dataSize, rawPtr)
        if status != noErr
        {
            return false
        }

        let ablPtr = rawPtr.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(ablPtr)
        var channelCount = 0
        for buffer in buffers
        {
            channelCount += Int(buffer.mNumberChannels)
        }
        return channelCount > 0
    }
}

// MARK: - Low-overhead CoreAudio hardware observer
final class AudioHardwareObserver: ObservableObject
{
    private let subject = PassthroughSubject<Void, Never>()
    var changePublisher: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

    private var installed: Bool = false

    init()
    {
        register()
    }

    deinit
    {
        unregister()
    }

    private func register()
    {
        guard installed == false else { return }
        var addrDevices = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var addrDefaultIn = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var addrDefaultOut = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let queue = DispatchQueue.main
        let sys = AudioObjectID(kAudioObjectSystemObject)

        _ = AudioObjectAddPropertyListenerBlock(sys, &addrDevices, queue) { [weak self] _, _ in
            self?.subject.send(())
        }
        _ = AudioObjectAddPropertyListenerBlock(sys, &addrDefaultIn, queue) { [weak self] _, _ in
            self?.subject.send(())
        }
        _ = AudioObjectAddPropertyListenerBlock(sys, &addrDefaultOut, queue) { [weak self] _, _ in
            self?.subject.send(())
        }

        installed = true
    }

    private func unregister()
    {
        guard installed else { return }
        // Intentionally omitted: removing blocks is optional; listeners end with object lifetime.
        installed = false
    }
}

// MARK: - Custom Styles for Premium UI

struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.semibold)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.regularMaterial) // Less transparent for better contrast
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        .white.opacity(0.08),
                                        Color(red: 0.2, green: 0.3, blue: 0.5).opacity(0.05),
                                        .black.opacity(0.02),
                                        .white.opacity(0.04)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(.white.opacity(0.25), lineWidth: 1.0) // Less harsh border
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                LinearGradient(
                                    colors: [.white.opacity(0.6), .clear, .clear, .white.opacity(0.2)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                    .shadow(color: .white.opacity(0.1), radius: 1, x: 0, y: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

struct PremiumButtonStyle: ButtonStyle {
    let isRecording: Bool
    let height: CGFloat
    
    init(isRecording: Bool = false, height: CGFloat = 44) {
        self.isRecording = isRecording
        self.height = height
    }
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .foregroundColor(isRecording ? .white : .black)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(
                        isRecording ? 
                        LinearGradient(colors: [.red.opacity(0.8), .red.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing) :
                        LinearGradient(colors: [Color.white.opacity(0.8), Color(red: 0.6, green: 0.7, blue: 0.9)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(.white.opacity(0.2), lineWidth: 1)
                    )
                    .shadow(color: (isRecording ? Color.red : Color.black).opacity(0.3), radius: 8, x: 0, y: 4)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .foregroundColor(.primary)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(.white.opacity(0.3), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 3)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

struct CompactButtonStyle: ButtonStyle {
    let isReady: Bool
    
    init(isReady: Bool = false) {
        self.isReady = isReady
    }
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.medium)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .foregroundColor(.primary)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isReady ?
                        LinearGradient(colors: [Color(red: 0.4, green: 0.5, blue: 0.7).opacity(0.3), Color(red: 0.2, green: 0.3, blue: 0.5).opacity(0.1)], startPoint: .top, endPoint: .bottom) :
                        LinearGradient(colors: [Color(red: 0.2, green: 0.3, blue: 0.5).opacity(0.1), Color(red: 0.1, green: 0.15, blue: 0.3).opacity(0.05)], startPoint: .top, endPoint: .bottom)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isReady ? .white.opacity(0.3) : Color(red: 0.4, green: 0.5, blue: 0.7).opacity(0.3), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

struct InlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundColor(.white)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: 0.3, green: 0.4, blue: 0.6).opacity(0.2))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.white.opacity(0.2), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct GlassToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
                .foregroundStyle(.primary)
            
            Spacer()
            
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(configuration.isOn ? 
                          AnyShapeStyle(LinearGradient(colors: [Color.white.opacity(0.9), Color(red: 0.6, green: 0.7, blue: 0.9)], startPoint: .leading, endPoint: .trailing)) :
                          AnyShapeStyle(.quaternary))
                    .frame(width: 44, height: 24)
                    .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                
                Circle()
                    .fill(configuration.isOn ? .black : .white)
                    .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 2)
                    .frame(width: 20, height: 20)
                    .offset(x: configuration.isOn ? 10 : -10)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isOn)
            }
            .onTapGesture {
                configuration.isOn.toggle()
            }
        }
    }
}

// MARK: - Glossy Card Style
struct GlossyCardBackground: View {
    let cornerRadius: CGFloat
    let isElevated: Bool
    
    init(cornerRadius: CGFloat = 20, isElevated: Bool = false) {
        self.cornerRadius = cornerRadius
        self.isElevated = isElevated
    }
    
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(.ultraThinMaterial)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.15),
                                .white.opacity(0.05),
                                .black.opacity(0.02),
                                .white.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(.white.opacity(isElevated ? 0.7 : 0.5), lineWidth: isElevated ? 2 : 1.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.7), .clear, .clear, .white.opacity(0.3)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(isElevated ? 0.6 : 0.4), radius: isElevated ? 35 : 25, x: 0, y: isElevated ? 18 : 12)
            .shadow(color: .black.opacity(isElevated ? 0.3 : 0.2), radius: isElevated ? 12 : 8, x: 0, y: isElevated ? 6 : 4)
            .shadow(color: .white.opacity(isElevated ? 0.25 : 0.15), radius: isElevated ? 3 : 2, x: 0, y: 1)
    }
}

// MARK: - Card Animation Modifier
struct CardAppearAnimation: ViewModifier {
    let delay: Double
    @Binding var appear: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(appear ? 1.0 : 0.96)
            .opacity(appear ? 1.0 : 0)
            .animation(.spring(response: 0.8, dampingFraction: 0.75, blendDuration: 0.2).delay(delay), value: appear)
    }
}
