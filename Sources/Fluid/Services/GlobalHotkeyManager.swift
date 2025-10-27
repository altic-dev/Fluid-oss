import Foundation
import AppKit

final class GlobalHotkeyManager: NSObject
{
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let asrService: ASRService
    private var shortcut: HotkeyShortcut
    private var stopAndProcessCallback: (() async -> Void)?
    private var pressAndHoldMode: Bool = SettingsStore.shared.pressAndHoldMode
    private var isKeyPressed = false
    
    private var isInitialized = false
    private var initializationTask: Task<Void, Never>?
    private var healthCheckTask: Task<Void, Never>?
    private let maxRetryAttempts = 5
    private let retryDelay: TimeInterval = 0.5
    private let healthCheckInterval: TimeInterval = 30.0

    init(asrService: ASRService, shortcut: HotkeyShortcut, stopAndProcessCallback: (() async -> Void)? = nil)
    {
        self.asrService = asrService
        self.shortcut = shortcut
        self.stopAndProcessCallback = stopAndProcessCallback
        super.init()
        
        initializeWithDelay()
    }
    
    private func initializeWithDelay() {
        DebugLogger.shared.debug("Starting delayed initialization...", source: "GlobalHotkeyManager")
        
        initializationTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 second delay
            
            await MainActor.run {
                self.setupGlobalHotkeyWithRetry()
            }
        }
    }

    func setStopAndProcessCallback(_ callback: @escaping () async -> Void)
    {
        self.stopAndProcessCallback = callback
    }

    private func setupGlobalHotkeyWithRetry() {
        for attempt in 1...maxRetryAttempts {
            DebugLogger.shared.debug("Setup attempt \(attempt)/\(maxRetryAttempts)", source: "GlobalHotkeyManager")
            
            if setupGlobalHotkey() {
                isInitialized = true
                DebugLogger.shared.info("Successfully initialized on attempt \(attempt)", source: "GlobalHotkeyManager")
                startHealthCheckTimer()
                return
            }
            
            if attempt < maxRetryAttempts {
                DebugLogger.shared.warning("Attempt \(attempt) failed, retrying in \(retryDelay) seconds...", source: "GlobalHotkeyManager")
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                    await MainActor.run {
                        self.setupGlobalHotkeyWithRetry()
                    }
                }
                return
            }
        }
        
        DebugLogger.shared.error("Failed to initialize after \(maxRetryAttempts) attempts", source: "GlobalHotkeyManager")
    }
    
    @discardableResult
    private func setupGlobalHotkey() -> Bool
    {
        cleanupEventTap()
        
        if !AXIsProcessTrusted() {
            if UserDefaults.standard.bool(forKey: "enableDebugLogs") {
                print("[GlobalHotkeyManager] Accessibility permissions not granted")
            }
            return false
        }

        let eventMask = (1 << CGEventType.keyDown.rawValue)
                    | (1 << CGEventType.keyUp.rawValue)
                    | (1 << CGEventType.flagsChanged.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleKeyEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        
        guard let tap = eventTap else {
            if UserDefaults.standard.bool(forKey: "enableDebugLogs") {
                print("[GlobalHotkeyManager] Failed to create CGEvent tap")
            }
            return false
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        guard let source = runLoopSource else {
            if UserDefaults.standard.bool(forKey: "enableDebugLogs") {
                print("[GlobalHotkeyManager] Failed to create CFRunLoopSource")
            }
            return false
        }
        
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        
        if !isEventTapEnabled() {
            if UserDefaults.standard.bool(forKey: "enableDebugLogs") {
                print("[GlobalHotkeyManager] Event tap could not be enabled")
            }
            cleanupEventTap()
            return false
        }
        
        if UserDefaults.standard.bool(forKey: "enableDebugLogs") {
            print("[GlobalHotkeyManager] Event tap successfully created and enabled")
        }
        return true
    }
    
    private func cleanupEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        
        eventTap = nil
        runLoopSource = nil
    }

    private func handleKeyEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>?
    {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        var eventModifiers: NSEvent.ModifierFlags = []
        if flags.contains(.maskSecondaryFn) { eventModifiers.insert(.function) }
        if flags.contains(.maskCommand) { eventModifiers.insert(.command) }
        if flags.contains(.maskAlternate) { eventModifiers.insert(.option) }
        if flags.contains(.maskControl) { eventModifiers.insert(.control) }
        if flags.contains(.maskShift) { eventModifiers.insert(.shift) }

        switch type
        {
        case .keyDown:
            if matchesShortcut(keyCode: keyCode, modifiers: eventModifiers)
            {
                if pressAndHoldMode
                {
                    if !isKeyPressed
                    {
                        isKeyPressed = true
                        startRecordingIfNeeded()
                    }
                }
                else
                {
                    toggleRecording()
                }
                return nil
            }

        case .keyUp:
            if pressAndHoldMode && isKeyPressed && matchesShortcut(keyCode: keyCode, modifiers: eventModifiers)
            {
                isKeyPressed = false
                stopRecordingIfNeeded()
                return nil
            }

        case .flagsChanged:
            guard shortcut.modifierFlags.isEmpty else { break }

            let isModifierPressed = flags.contains(.maskSecondaryFn)
                || flags.contains(.maskCommand)
                || flags.contains(.maskAlternate)
                || flags.contains(.maskControl)
                || flags.contains(.maskShift)

            if keyCode == shortcut.keyCode
            {
                if pressAndHoldMode
                {
                    if isModifierPressed
                    {
                        if !isKeyPressed
                        {
                            isKeyPressed = true
                            startRecordingIfNeeded()
                        }
                    }
                    else if isKeyPressed
                    {
                        isKeyPressed = false
                        stopRecordingIfNeeded()
                    }
                }
                else if isModifierPressed
                {
                    toggleRecording()
                }
                return nil
            }

        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }

    func enablePressAndHoldMode(_ enable: Bool)
    {
        pressAndHoldMode = enable
        if !enable && isKeyPressed
        {
            isKeyPressed = false
            stopRecordingIfNeeded()
        }
        else if enable
        {
            isKeyPressed = false
        }
    }

    private func toggleRecording()
    {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            if self.asrService.isRunning
            {
                await self.stopRecordingInternal()
            }
            else
            {
                self.asrService.start()
            }
        }
    }

    private func startRecordingIfNeeded()
    {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            if !self.asrService.isRunning
            {
                self.asrService.start()
            }
        }
    }

    private func stopRecordingIfNeeded()
    {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            await self.stopRecordingInternal()
        }
    }

    @MainActor
    private func stopRecordingInternal() async
    {
        guard asrService.isRunning else { return }
        if let callback = stopAndProcessCallback
        {
            await callback()
        }
        else
        {
            asrService.stopWithoutTranscription()
        }
    }

    private func matchesShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool
    {
        let relevantModifiers: NSEvent.ModifierFlags = modifiers.intersection([.function, .command, .option, .control, .shift])
        let shortcutModifiers = shortcut.modifierFlags.intersection([.function, .command, .option, .control, .shift])
        return keyCode == shortcut.keyCode && relevantModifiers == shortcutModifiers
    }

    func updateShortcut(_ newShortcut: HotkeyShortcut)
    {
        shortcut = newShortcut
        
        if UserDefaults.standard.bool(forKey: "enableDebugLogs") {
            print("[GlobalHotkeyManager] Updating shortcut to: \(newShortcut.displayString)")
        }
        
        if setupGlobalHotkey() {
            isInitialized = true
            if UserDefaults.standard.bool(forKey: "enableDebugLogs") {
                print("[GlobalHotkeyManager] Shortcut update successful")
            }
            startHealthCheckTimer()
        } else {
            print("[GlobalHotkeyManager] ERROR: Failed to update shortcut")
        }
    }
    
    func isEventTapEnabled() -> Bool {
        guard let tap = eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }
    
    func validateEventTapHealth() -> Bool {
        guard isInitialized else { return false }
        return isEventTapEnabled()
    }
    
    func reinitialize() {
        if UserDefaults.standard.bool(forKey: "enableDebugLogs") {
            print("[GlobalHotkeyManager] Manual reinitialization requested")
        }
        
        initializationTask?.cancel()
        healthCheckTask?.cancel()
        isInitialized = false
        initializeWithDelay()
    }

    private func startHealthCheckTimer() {
        healthCheckTask?.cancel()
        healthCheckTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(healthCheckInterval * 1_000_000_000))
                
                guard !Task.isCancelled else { break }
                
                await MainActor.run {
                    if !self.validateEventTapHealth() {
                        if UserDefaults.standard.bool(forKey: "enableDebugLogs") {
                            print("[GlobalHotkeyManager] Health check failed, attempting to recover")
                        }
                        
                        if self.setupGlobalHotkey() {
                            if UserDefaults.standard.bool(forKey: "enableDebugLogs") {
                                print("[GlobalHotkeyManager] Health check recovery successful")
                            }
                        } else {
                            print("[GlobalHotkeyManager] Health check recovery failed")
                            self.isInitialized = false
                        }
                    }
                }
            }
        }
    }
    
    deinit
    {
        initializationTask?.cancel()
        healthCheckTask?.cancel()
        cleanupEventTap()
        
        if UserDefaults.standard.bool(forKey: "enableDebugLogs") {
            print("[GlobalHotkeyManager] Deinitialized and cleaned up")
        }
    }
}


