import Foundation
import ServiceManagement
import ApplicationServices
import AppKit

final class SettingsStore
{
    static let shared = SettingsStore()
    private let defaults = UserDefaults.standard

    private init() {}

    // Keys
    private enum Keys
    {
        static let enableAIProcessing = "EnableAIProcessing"
         static let enableDebugLogs = "EnableDebugLogs"
        static let availableAIModels = "AvailableAIModels"
        static let availableModelsByProvider = "AvailableModelsByProvider"
        static let selectedAIModel = "SelectedAIModel"
        static let selectedModelByProvider = "SelectedModelByProvider"
        static let selectedProviderID = "SelectedProviderID"
        static let providerAPIKeys = "ProviderAPIKeys"
        static let savedProviders = "SavedProviders"
        static let hotkeyShortcutKey = "HotkeyShortcutKey"
         static let preferredInputDeviceUID = "PreferredInputDeviceUID"
         static let preferredOutputDeviceUID = "PreferredOutputDeviceUID"
        static let visualizerNoiseThreshold = "VisualizerNoiseThreshold"
        static let launchAtStartup = "LaunchAtStartup"
        static let showInDock = "ShowInDock"
        static let pressAndHoldMode = "PressAndHoldMode"
        static let enableStreamingPreview = "EnableStreamingPreview"
        static let copyTranscriptionToClipboard = "CopyTranscriptionToClipboard"
        static let autoUpdateCheckEnabled = "AutoUpdateCheckEnabled"
        static let lastUpdateCheckDate = "LastUpdateCheckDate"
    }

    struct SavedProvider: Codable, Identifiable, Hashable
    {
        let id: String
        let name: String
        let baseURL: String
        let apiKey: String
        let models: [String]

        init(id: String = UUID().uuidString, name: String, baseURL: String, apiKey: String, models: [String] = [])
        {
            self.id = id
            self.name = name
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.models = models
        }
    }

    var enableAIProcessing: Bool
    {
        get { defaults.bool(forKey: Keys.enableAIProcessing) }
        set { defaults.set(newValue, forKey: Keys.enableAIProcessing) }
    }

    var availableModels: [String]
    {
        get { (defaults.array(forKey: Keys.availableAIModels) as? [String]) ?? [] }
        set { defaults.set(newValue, forKey: Keys.availableAIModels) }
    }

    var availableModelsByProvider: [String: [String]]
    {
        get { (defaults.dictionary(forKey: Keys.availableModelsByProvider) as? [String: [String]]) ?? [:] }
        set { defaults.set(newValue, forKey: Keys.availableModelsByProvider) }
    }

     var enableDebugLogs: Bool
     {
         get { defaults.bool(forKey: Keys.enableDebugLogs) }
         set { defaults.set(newValue, forKey: Keys.enableDebugLogs) }
     }

    var selectedModel: String?
    {
        get { defaults.string(forKey: Keys.selectedAIModel) }
        set { defaults.set(newValue, forKey: Keys.selectedAIModel) }
    }

    var selectedModelByProvider: [String: String]
    {
        get { (defaults.dictionary(forKey: Keys.selectedModelByProvider) as? [String: String]) ?? [:] }
        set { defaults.set(newValue, forKey: Keys.selectedModelByProvider) }
    }

    var providerAPIKeys: [String: String]
    {
        get { (defaults.dictionary(forKey: Keys.providerAPIKeys) as? [String: String]) ?? [:] }
        set { defaults.set(newValue, forKey: Keys.providerAPIKeys) }
    }

    var selectedProviderID: String
    {
        get { defaults.string(forKey: Keys.selectedProviderID) ?? "openai" }
        set { defaults.set(newValue, forKey: Keys.selectedProviderID) }
    }

    var savedProviders: [SavedProvider]
    {
        get
        {
            guard let data = defaults.data(forKey: Keys.savedProviders),
                  let decoded = try? JSONDecoder().decode([SavedProvider].self, from: data) else { return [] }
            return decoded
        }
        set
        {
            if let encoded = try? JSONEncoder().encode(newValue)
            {
                defaults.set(encoded, forKey: Keys.savedProviders)
            }
        }
    }

    var hotkeyShortcut: HotkeyShortcut
    {
        get
        {
            if let data = defaults.data(forKey: Keys.hotkeyShortcutKey),
               let shortcut = try? JSONDecoder().decode(HotkeyShortcut.self, from: data)
            {
                return shortcut
            }
            return HotkeyShortcut(keyCode: 61, modifierFlags: [])
        }
        set
        {
            if let data = try? JSONEncoder().encode(newValue)
            {
                defaults.set(data, forKey: Keys.hotkeyShortcutKey)
            }
        }
    }

    var pressAndHoldMode: Bool
    {
        get { defaults.bool(forKey: Keys.pressAndHoldMode) }
        set { defaults.set(newValue, forKey: Keys.pressAndHoldMode) }
    }

    var enableStreamingPreview: Bool
    {
        get {
            let value = defaults.object(forKey: Keys.enableStreamingPreview)
            return value as? Bool ?? true // Default to true (enabled)
        }
        set { defaults.set(newValue, forKey: Keys.enableStreamingPreview) }
    }

    var copyTranscriptionToClipboard: Bool
    {
        get { defaults.bool(forKey: Keys.copyTranscriptionToClipboard) }
        set { defaults.set(newValue, forKey: Keys.copyTranscriptionToClipboard) }
    }

     var preferredInputDeviceUID: String?
     {
         get { defaults.string(forKey: Keys.preferredInputDeviceUID) }
         set { defaults.set(newValue, forKey: Keys.preferredInputDeviceUID) }
     }

     var preferredOutputDeviceUID: String?
     {
         get { defaults.string(forKey: Keys.preferredOutputDeviceUID) }
         set { defaults.set(newValue, forKey: Keys.preferredOutputDeviceUID) }
     }
    
    var visualizerNoiseThreshold: Double
    {
        get {
            let value = defaults.double(forKey: Keys.visualizerNoiseThreshold)
            return value == 0.0 ? 0.4 : value // Default to 0.4 if not set
        }
        set { defaults.set(newValue, forKey: Keys.visualizerNoiseThreshold) }
    }

    // MARK: - Preferences Settings

    var launchAtStartup: Bool
    {
        get { defaults.bool(forKey: Keys.launchAtStartup) }
        set {
            defaults.set(newValue, forKey: Keys.launchAtStartup)
            // Update launch agent registration
            updateLaunchAtStartup(newValue)
        }
    }

    // MARK: - Initialization Methods

    func initializeAppSettings() {
        #if os(macOS)
        // Apply dock visibility setting on app launch
        let dockVisible = showInDock
        DebugLogger.shared.info("Initializing app with dock visibility: \(dockVisible)", source: "SettingsStore")

        // Set activation policy based on saved preference
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(dockVisible ? .regular : .accessory)
        }
        #endif
    }

    var showInDock: Bool
    {
        get {
            let value = defaults.object(forKey: Keys.showInDock)
            return value as? Bool ?? true // Default to true if not set
        }
        set {
            defaults.set(newValue, forKey: Keys.showInDock)
            // Update dock visibility
            updateDockVisibility(newValue)
        }
    }

    var autoUpdateCheckEnabled: Bool
    {
        get {
            let value = defaults.object(forKey: Keys.autoUpdateCheckEnabled)
            return value as? Bool ?? true // Default to enabled
        }
        set {
            defaults.set(newValue, forKey: Keys.autoUpdateCheckEnabled)
        }
    }

    var lastUpdateCheckDate: Date?
    {
        get {
            return defaults.object(forKey: Keys.lastUpdateCheckDate) as? Date
        }
        set {
            defaults.set(newValue, forKey: Keys.lastUpdateCheckDate)
        }
    }

    // MARK: - Update Check Helper

    func shouldCheckForUpdates() -> Bool {
        guard autoUpdateCheckEnabled else { return false }
        
        guard let lastCheck = lastUpdateCheckDate else {
            // Never checked before, should check
            return true
        }
        
        // Check if more than 24 hours have passed
        let dayInSeconds: TimeInterval = 24 * 60 * 60
        return Date().timeIntervalSince(lastCheck) >= dayInSeconds
    }

    func updateLastCheckDate() {
        lastUpdateCheckDate = Date()
    }

    // MARK: - Private Methods

    private func updateLaunchAtStartup(_ enabled: Bool) {
        #if os(macOS)
        // Note: SMAppService.mainApp requires the app to be signed with Developer ID
        // and have proper entitlements. This may not work in development builds.
        let service = SMAppService.mainApp

        do {
            if enabled {
                try service.register()
                DebugLogger.shared.info("Successfully registered for launch at startup", source: "SettingsStore")
            } else {
                try service.unregister()
                DebugLogger.shared.info("Successfully unregistered from launch at startup", source: "SettingsStore")
            }
        } catch {
            DebugLogger.shared.error("Failed to update launch at startup: \(error)", source: "SettingsStore")
            // In development, this is expected to fail without proper signing/entitlements
            // The setting is still saved and will work when the app is properly signed
        }
        #endif
    }

    private func updateDockVisibility(_ visible: Bool) {
        #if os(macOS)
        // IMPORTANT: This is a simplified implementation for development
        // In production, consider these approaches:
        // 1. Use LSUIElement in Info.plist to control default dock visibility
        // 2. Implement a proper helper app or service for dock management
        // 3. Use NSApplication.shared.setActivationPolicy() for better control

        // For now, we'll try multiple approaches with fallbacks

        DebugLogger.shared.debug("Attempting to update dock visibility to: \(visible ? "visible" : "hidden")", source: "SettingsStore")

        // Method 1: Try the deprecated TransformProcessType (may not work on all systems)
        let transformState = visible ? ProcessApplicationTransformState(kProcessTransformToForegroundApplication)
                                     : ProcessApplicationTransformState(kProcessTransformToUIElementApplication)

        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kCurrentProcess))
        let result = TransformProcessType(&psn, transformState)

        if result == 0 {
            DebugLogger.shared.info("✓ Dock visibility updated using TransformProcessType", source: "SettingsStore")
        } else {
            DebugLogger.shared.warning("⚠️ TransformProcessType failed (error: \(result)). This is expected on some macOS versions.", source: "SettingsStore")
            DebugLogger.shared.debug("   The setting is saved and will be applied when possible.", source: "SettingsStore")
        }

        // Method 2: Try to notify the system of the change
        // This may help with some system caches
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.setActivationPolicy(visible ? .regular : .accessory)
            DebugLogger.shared.info("✓ Activation policy updated to: \(visible ? "regular" : "accessory")", source: "SettingsStore")
        }

        // Store the intended state for reference
        UserDefaults.standard.set(visible, forKey: "IntendedDockVisibility")
        DebugLogger.shared.info("✓ Dock visibility preference saved: \(visible)", source: "SettingsStore")
        #endif
    }
}


