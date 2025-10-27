import AppKit
import Combine
import PromiseKit
import SwiftUI

@MainActor
final class MenuBarManager: ObservableObject {
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var isSetup: Bool = false
    
    // References to app state
    private weak var asrService: ASRService?
    private var cancellables = Set<AnyCancellable>()
    
    // Overlay management (persistent, independent of window lifecycle)
    private var overlay: ListeningOverlayController?
    private var overlayVisible: Bool = false
    
    @Published var isRecording: Bool = false
    @Published var aiProcessingEnabled: Bool = false
    
    init() {
        // Don't setup menu bar immediately - defer until app is ready
        // Initialize from persisted setting
        aiProcessingEnabled = SettingsStore.shared.enableAIProcessing
        // Reflect changes to menu when toggled from elsewhere (e.g., General tab)
        $aiProcessingEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenu()
            }
            .store(in: &cancellables)
    }
    
    func initializeMenuBar() {
        guard !isSetup else { return }
        
        // Ensure we're on main thread and app is active
        DispatchQueue.main.async { [weak self] in
            self?.setupMenuBarSafely()
        }
    }
    
    deinit {
        statusItem = nil
    }
    
    func configure(asrService: ASRService) {
        self.asrService = asrService
        
        // Initialize overlay controller (persists for app lifetime)
        if overlay == nil {
            overlay = ListeningOverlayController(asrService: asrService)
        }
        
        // Subscribe to recording state changes
        asrService.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRunning in
                self?.isRecording = isRunning
                self?.updateMenuBarIcon()
                self?.updateMenu()
                
                // Handle overlay lifecycle (independent of window state)
                self?.handleOverlayState(isRunning: isRunning, asrService: asrService)
            }
            .store(in: &cancellables)
        
        // Subscribe to partial transcription updates for streaming preview
        asrService.$partialTranscription
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newText in
                self?.overlay?.updateTranscriptionText(newText)
            }
            .store(in: &cancellables)
        
        // Subscribe to AI processing state
        aiProcessingEnabled = SettingsStore.shared.enableAIProcessing
    }
    
    private func handleOverlayState(isRunning: Bool, asrService: ASRService) {
        // Prevent rapid state changes that could cause cycles
        guard overlayVisible != isRunning else { return }
        
        let delay: DispatchTimeInterval = .milliseconds(150)
        if isRunning {
            overlayVisible = true
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, self.overlayVisible else { return }
                let hosting = NSHostingView(rootView: ListeningOverlayView(audioLevelPublisher: asrService.audioLevelPublisher))
                hosting.wantsLayer = true
                hosting.layer?.cornerRadius = 20
                hosting.layer?.masksToBounds = true
                let showPreview = SettingsStore.shared.enableStreamingPreview
                self.overlay?.show(with: hosting, showPreview: showPreview)
            }
        } else {
            overlayVisible = false
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, !self.overlayVisible else { return }
                self.overlay?.hide()
                // Clear transcription text when hiding overlay
                self.overlay?.updateTranscriptionText("")
            }
        }
    }
    
    // MARK: - Public API for overlay management (for ContentView to sync)
    func updateOverlayTranscription(_ text: String) {
        overlay?.updateTranscriptionText(text)
    }
    
    func updateOverlayPreviewSetting(_ enabled: Bool) {
        overlay?.setPreviewEnabled(enabled)
    }
    
    private func setupMenuBarSafely() {
        // Check if window server connection is available
        guard NSApp.isActive || NSApp.isRunning else {
            // Retry after a short delay if app isn't ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.setupMenuBarSafely()
            }
            return
        }
        
        do {
            try setupMenuBar()
            isSetup = true
        } catch {
            // If setup fails, retry after delay
            print("MenuBar setup failed, retrying: \(error)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.setupMenuBarSafely()
            }
        }
    }
    
    private func setupMenuBar() throws {
        // Ensure we're not already set up
        guard !isSetup else { return }
        
        // Create status item with error handling
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        guard let statusItem = statusItem else { 
            throw NSError(domain: "MenuBarManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create status item"])
        }
        
        // Set initial icon
        updateMenuBarIcon()
        
        // Create menu
        menu = NSMenu()
        statusItem.menu = menu
        
        updateMenu()
    }
    
    private func updateMenuBarIcon() {
        guard let statusItem = statusItem else { return }
        
        // Use custom F icon instead of microphone
        let image = createFluidIcon(isRecording: isRecording)
        
        statusItem.button?.image = image
        statusItem.button?.imagePosition = .imageOnly
    }
    
    private func createFluidIcon(isRecording: Bool) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        
        image.lockFocus()
        
        // Create F shape path
        let path = NSBezierPath()
        let lineWidth: CGFloat = 2.0
        
        // F shape coordinates (scaled to 16x16)
        let leftX: CGFloat = 2
        let rightX: CGFloat = 12
        let topY: CGFloat = 14
        let bottomY: CGFloat = 2
        let middleY: CGFloat = 8.5
        
        // Vertical line (left side of F)
        path.move(to: NSPoint(x: leftX, y: bottomY))
        path.line(to: NSPoint(x: leftX, y: topY))
        
        // Top horizontal line (full width)
        path.line(to: NSPoint(x: rightX, y: topY))
        
        // Middle horizontal line
        path.move(to: NSPoint(x: leftX, y: middleY))
        path.line(to: NSPoint(x: rightX - 2, y: middleY))
        
        // Set color based on recording state
        let color = isRecording ? NSColor.systemRed : NSColor.controlAccentColor
        color.set()
        
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
        
        image.unlockFocus()
        image.isTemplate = true
        
        return image
    }
    
    private func updateMenu() {
        guard let menu = menu else { return }
        
        menu.removeAllItems()
        
        // Status indicator
        let statusTitle = isRecording ? "Recording..." : "Ready to Record"
        let statusItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        
        menu.addItem(.separator())
        
        // Start/Stop Recording
        let recordingAction = isRecording ? "Stop Recording" : "Start Recording"
        let recordingItem = NSMenuItem(title: recordingAction, action: #selector(toggleRecording), keyEquivalent: "")
        recordingItem.target = self
        
        // Show hotkey if available
        let hotkeyShortcut = SettingsStore.shared.hotkeyShortcut
        recordingItem.keyEquivalent = "" // We'll show it in the title instead
        if !hotkeyShortcut.displayString.isEmpty {
            recordingItem.title = "\(recordingAction) (\(hotkeyShortcut.displayString))"
        }
        
        menu.addItem(recordingItem)
        
        // AI Processing Toggle
        let aiTitle = aiProcessingEnabled ? "Disable AI Processing" : "Enable AI Processing"
        let aiItem = NSMenuItem(title: aiTitle, action: #selector(toggleAIProcessing), keyEquivalent: "")
        aiItem.target = self
        menu.addItem(aiItem)
        
        menu.addItem(.separator())
        
        // Open Main Window
        let openItem = NSMenuItem(title: "Open FluidVoice", action: #selector(openMainWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        
        // Check for Updates
        let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)
        
        menu.addItem(.separator())
        
        // Quit
        let quitItem = NSMenuItem(title: "Quit FluidVoice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
    }
    
    @objc private func toggleRecording() {
        guard let asrService = asrService else { return }
        
        if isRecording {
            Task {
                _ = await asrService.stop()
            }
        } else {
            asrService.start()
        }
    }
    
    @objc private func toggleAIProcessing() {
        aiProcessingEnabled.toggle()
        // Persist and broadcast change
        SettingsStore.shared.enableAIProcessing = aiProcessingEnabled
        // If a ContentView has bound to MenuBarManager, its onChange sync will mirror this
        updateMenu()
    }
    
    @objc private func checkForUpdates(_ sender: Any?) {
        print("🔎 Menu action: Check for Updates…")
        NSLog("🔎 Menu action: Check for Updates…")

        // Call the AppDelegate's manual update check method if available
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.checkForUpdatesManually()
            return
        }

        // Fallback: perform direct, tolerant check so the menu item always does something
        Task { @MainActor in
            do {
                try await SimpleUpdater.shared.checkAndUpdate(owner: "altic-dev", repo: "Fluid-oss")
                let ok = NSAlert()
                ok.messageText = "Update Found!"
                ok.informativeText = "A new version is available and will be installed now."
                ok.alertStyle = .informational
                ok.addButton(withTitle: "OK")
                ok.runModal()
            } catch {
                let msg = NSAlert()
                if let pmkError = error as? PMKError, pmkError.isCancelled {
                    msg.messageText = "You’re Up To Date"
                    msg.informativeText = "You're already running the latest version of FluidVoice."
                } else {
                    msg.messageText = "Update Check Failed"
                    msg.informativeText = "Unable to check for updates. Please try again later.\n\nError: \(error.localizedDescription)"
                }
                msg.alertStyle = .informational
                msg.runModal()
            }
        }
    }
    
    @objc private func openMainWindow() {
        // First, unhide the app if it's hidden
        if NSApp.isHidden {
            NSApp.unhide(nil)
        }
        
        // Activate the app and bring it to the front
        NSApp.activate(ignoringOtherApps: true)
        
        // Find and restore the main window
        var foundWindow = false
        for window in NSApp.windows {
            if window.title.contains("FluidVoice") || window.isMainWindow || window.contentView != nil {
                // Handle minimized windows
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                
                // Bring to current space and make key
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
                foundWindow = true
                break
            }
        }
        
        // If no window found, try to activate any available window
        if !foundWindow && !NSApp.windows.isEmpty {
            if let firstWindow = NSApp.windows.first {
                if firstWindow.isMiniaturized {
                    firstWindow.deminiaturize(nil)
                }
                firstWindow.makeKeyAndOrderFront(nil)
                firstWindow.orderFrontRegardless()
                foundWindow = true
            }
        }
        
        // Final attempt: ensure app is active and visible
        if foundWindow {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
