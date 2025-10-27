//
//  TalkingAnimations.swift
//  fluid
//
//  Created by Assistant
//

import SwiftUI
import Combine
import AppKit
import CoreGraphics

// MARK: - Active App Tracker
class ActiveAppTracker: ObservableObject {
    @Published var activeAppName: String = "Unknown App"
    @Published var activeWindowTitle: String = ""
    private var timer: Timer?
    
    init() {
        updateActiveApp()
        startTracking()
    }
    
    private func startTracking() {
        // Reduced frequency for app tracking - 2 FPS is sufficient for app name updates
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            self.updateActiveApp()
        }
    }
    
    private func updateActiveApp() {
        if let frontmostApp = NSWorkspace.shared.frontmostApplication {
            activeAppName = frontmostApp.localizedName ?? "Unknown App"
            activeWindowTitle = fetchFrontmostWindowTitle(for: frontmostApp.processIdentifier) ?? ""
        }
    }
    
    private func fetchFrontmostWindowTitle(for ownerPid: pid_t) -> String? {
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

    deinit {
        timer?.invalidate()
    }
}

// MARK: - Spokenly-Style Talking Animation Configuration
struct TalkingAnimationConfig: AudioVisualizationConfig {
    let noiseThreshold: CGFloat // Now dynamic - set from user preference
    let maxAnimationScale: CGFloat = 2.5
    let animationSpring: Animation = .spring(response: 0.3, dampingFraction: 0.7, blendDuration: 0.1)
    
    init(noiseThreshold: CGFloat = 0.4) {
        self.noiseThreshold = max(0.01, min(0.8, noiseThreshold)) // Clamp to valid range
    }
    
    // Bar-specific properties
    let barCount: Int = 12
    let barSpacing: CGFloat = 3
    let barWidth: CGFloat = 5
    let minBarHeight: CGFloat = 4
    let maxBarHeight: CGFloat = 32
    let animationSpeed: Double = 0.12 // Optimized animation speed
    let containerWidth: CGFloat = 140
    let containerHeight: CGFloat = 40
    
    // Performance optimization settings - much faster and more responsive
    let maxFPS: Double = 60.0 // Higher FPS for smoothness
    let idleAnimationReduction: Int = 4 // Less aggressive reduction
    let activeFPS: Double = 60.0 // High FPS during active speech
    let idleFPS: Double = 30.0 // Higher idle FPS
    let silenceFPS: Double = 10.0 // Higher silence FPS
}

// MARK: - Spokenly-Style Audio Visualization View
struct TalkingAudioVisualizationView: View {
    @StateObject private var data: AudioVisualizationData
    @State private var dynamicNoiseThreshold: CGFloat = CGFloat(SettingsStore.shared.visualizerNoiseThreshold)
    
    // Dynamic config that updates with settings
    private var config: TalkingAnimationConfig {
        TalkingAnimationConfig(noiseThreshold: dynamicNoiseThreshold)
    }
    
    init(audioLevelPublisher: AnyPublisher<CGFloat, Never>) {
        self._data = StateObject(wrappedValue: AudioVisualizationData(audioLevelPublisher: audioLevelPublisher))
    }
    
    var body: some View {
        SpokenlyWaveform(
            config: config,
            audioLevel: data.audioLevel,
            isActive: data.audioLevel > config.noiseThreshold
        )
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            // Update threshold when UserDefaults changes
            let newThreshold = CGFloat(SettingsStore.shared.visualizerNoiseThreshold)
            if newThreshold != dynamicNoiseThreshold {
                dynamicNoiseThreshold = newThreshold
            }
        }
    }
}

// MARK: - Spokenly-Style Clean Waveform
struct SpokenlyWaveform: View {
    let config: TalkingAnimationConfig
    let audioLevel: CGFloat
    let isActive: Bool
    
    @State private var barHeights: [CGFloat] = []
    @State private var barOpacities: [Double] = []
    @State private var animationPhases: [Double] = []
    @State private var animationTrigger: Int = 0
    @State private var lastUpdateTime: TimeInterval = 0
    @State private var isViewVisible: Bool = true
    
    private let animationTimer = Timer.publish(every: 0.016, on: .main, in: .common).autoconnect() // 60 FPS base timer
    
    var body: some View {
        HStack(spacing: config.barSpacing) {
            ForEach(0..<config.barCount, id: \.self) { index in
                SpokenlyBar(
                    height: index < barHeights.count ? barHeights[index] : config.minBarHeight,
                    opacity: index < barOpacities.count ? barOpacities[index] : 0.4,
                    index: index,
                    config: config,
                    isActive: isActive
                )
            }
        }
        .frame(width: config.containerWidth, height: config.containerHeight)
        .onAppear {
            initializeBars()
            isViewVisible = true
        }
        .onDisappear {
            isViewVisible = false
        }
        .onReceive(animationTimer) { _ in
            if isViewVisible {
                updateBars()
            }
        }
    }
    
    private func initializeBars() {
        barHeights = Array(repeating: config.minBarHeight, count: config.barCount)
        barOpacities = Array(repeating: 0.4, count: config.barCount)
        animationPhases = (0..<config.barCount).map { _ in Double.random(in: 0...2 * Double.pi) }
    }
    
    private func updateBars() {
        let currentTime = Date().timeIntervalSince1970
        
        // Simple frame limiting - much more responsive
        let frameTime = 1.0 / 60.0 // 60 FPS always for real-time feel
        if currentTime - lastUpdateTime < frameTime { return }
        lastUpdateTime = currentTime
        
        // Safety check
        guard barHeights.count == config.barCount && barOpacities.count == config.barCount else { return }
        
        // Direct real-time animation based on current audio level
        if audioLevel <= config.noiseThreshold { // USE THE USER-CONTROLLABLE THRESHOLD!
            // Complete stillness
            for i in 0..<min(config.barCount, barHeights.count) {
                barHeights[i] = config.minBarHeight
                barOpacities[i] = 0.3
            }
        } else {
            // Real-time responsive animation
            let audioInfluence = Double(audioLevel) * 2.0
            
            for i in 0..<min(config.barCount, barHeights.count) {
                // Fast frequency for immediate response
                let frequency = 3.0 + Double(i) * 0.4
                let phase = animationPhases[i]
                let waveValue = sin(currentTime * frequency + phase)
                let normalizedWave = (waveValue + 1) / 2
                
                // Direct audio-responsive calculation
                let heightMultiplier = normalizedWave * audioInfluence + 0.2
                let heightRange = config.maxBarHeight - config.minBarHeight
                let newHeight = config.minBarHeight + heightRange * CGFloat(min(heightMultiplier, 1.0))
                
                barHeights[i] = newHeight
                barOpacities[i] = 0.6 + (audioInfluence * 0.4)
            }
        }
    }
    
}

// MARK: - Premium Talking Animation Configuration
struct EnhancedTalkingAnimationConfig: AudioVisualizationConfig {
    let noiseThreshold: CGFloat // Now dynamic - set from user preference
    let maxAnimationScale: CGFloat = 2.8
    let animationSpring: Animation = .interpolatingSpring(stiffness: 400, damping: 20)
    
    init(noiseThreshold: CGFloat = 0.4) {
        self.noiseThreshold = max(0.01, min(0.8, noiseThreshold)) // Clamp to valid range
    }
    
    let particleCount: Int = 9
    let particleSpacing: CGFloat = 4
    let minParticleSize: CGFloat = 4
    let maxParticleSize: CGFloat = 16
    let baseOpacity: Double = 0.2
    let maxOpacity: Double = 0.8
}

struct EnhancedTalkingAudioVisualizationView: View {
    @StateObject private var data: AudioVisualizationData
    @State private var dynamicNoiseThreshold: CGFloat = CGFloat(SettingsStore.shared.visualizerNoiseThreshold)
    
    // Dynamic config that updates with settings
    private var config: EnhancedTalkingAnimationConfig {
        EnhancedTalkingAnimationConfig(noiseThreshold: dynamicNoiseThreshold)
    }
    
    init(audioLevelPublisher: AnyPublisher<CGFloat, Never>) {
        self._data = StateObject(wrappedValue: AudioVisualizationData(audioLevelPublisher: audioLevelPublisher))
    }
    
    var body: some View {
        HStack(spacing: config.particleSpacing) {
            ForEach(0..<config.particleCount, id: \.self) { index in
                PremiumTalkingParticle(
                    audioLevel: data.audioLevel,
                    config: config,
                    index: index
                )
            }
        }
        .frame(width: CGFloat(config.particleCount) * (config.maxParticleSize + config.particleSpacing) - config.particleSpacing)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            // Update threshold when UserDefaults changes
            let newThreshold = CGFloat(SettingsStore.shared.visualizerNoiseThreshold)
            if newThreshold != dynamicNoiseThreshold {
                dynamicNoiseThreshold = newThreshold
            }
        }
    }
}

struct PremiumTalkingParticle: View {
    let audioLevel: CGFloat
    let config: EnhancedTalkingAnimationConfig
    let index: Int
    
    @State private var animationPhase: Double = 0
    @State private var pulseScale: CGFloat = 1.0
    @State private var rotationAngle: Double = 0
    @State private var randomOffset: Double = Double.random(in: 0...2 * Double.pi)
    @State private var animationTrigger: Int = 0
    @State private var lastParticleUpdateTime: TimeInterval = 0
    @State private var isParticleVisible: Bool = true
    
    private let particleTimer = Timer.publish(every: 0.033, on: .main, in: .common).autoconnect() // 30 FPS
    
    private var isActive: Bool {
        audioLevel > config.noiseThreshold
    }
    
    private var particleSize: CGFloat {
        if !isActive { return config.minParticleSize }
        
        let waveValue = sin(animationPhase + Double(index) * 0.8 + randomOffset)
        let normalizedWave = (waveValue + 1) / 2
        let audioMultiplier = pow(audioLevel, 0.6) * 1.5
        let sizeRange = config.maxParticleSize - config.minParticleSize
        
        return config.minParticleSize + (sizeRange * CGFloat(normalizedWave) * min(audioMultiplier, 1.0))
    }
    
    private var particleOpacity: Double {
        if !isActive { return config.baseOpacity }
        let opacityRange = config.maxOpacity - config.baseOpacity
        return config.baseOpacity + (opacityRange * Double(audioLevel))
    }
    
    var body: some View {
        ZStack {
            // Outer glow ring
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [
                            Color.clear,
                            Color.purple.opacity(0.2),
                            Color.indigo.opacity(0.08),
                            Color.clear
                        ]),
                        center: .center,
                        startRadius: particleSize * 0.3,
                        endRadius: particleSize * 1.8
                    )
                )
                .frame(width: particleSize * 2.5, height: particleSize * 2.5)
                .opacity(isActive ? 0.6 : 0.1)
                .blur(radius: 2)
            
            // Main particle
            Circle()
                .fill(
                    AngularGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color.gray.opacity(0.6), location: 0.0),
                            .init(color: Color.purple.opacity(0.7), location: 0.25),
                            .init(color: Color.indigo.opacity(0.8), location: 0.5),
                            .init(color: Color.black.opacity(0.9), location: 0.75),
                            .init(color: Color.gray.opacity(0.6), location: 1.0)
                        ]),
                        center: .center,
                        startAngle: .degrees(rotationAngle),
                        endAngle: .degrees(rotationAngle + 360)
                    )
                )
                .frame(width: particleSize, height: particleSize)
                .opacity(particleOpacity)
                .scaleEffect(pulseScale)
                .overlay(
                    Circle()
                        .fill(
                            RadialGradient(
                                gradient: Gradient(colors: [
                                    Color.white.opacity(0.3),
                                    Color.white.opacity(0.1),
                                    Color.clear
                                ]),
                                center: UnitPoint(x: 0.3, y: 0.3),
                                startRadius: 0,
                                endRadius: particleSize * 0.6
                            )
                        )
                        .frame(width: particleSize, height: particleSize)
                )
                .shadow(color: Color.purple.opacity(0.4), radius: 4, x: 0, y: 2)
                .shadow(color: Color.indigo.opacity(0.3), radius: 8, x: 0, y: 0)
        }
        .animation(.easeInOut(duration: 0.12), value: particleSize)
        .animation(.easeInOut(duration: 0.15), value: particleOpacity)
        .onReceive(particleTimer) { _ in
            if isParticleVisible {
                updateParticleAnimation()
            }
        }
        .onAppear {
            isParticleVisible = true
        }
        .onDisappear {
            isParticleVisible = false
        }
    }
    
    private func updateParticleAnimation() {
        let currentTime = Date().timeIntervalSince1970
        
        // Simple frame limiting for consistent 30 FPS
        if currentTime - lastParticleUpdateTime < 0.033 { return }
        lastParticleUpdateTime = currentTime
        
        animationTrigger += 1
        
        // Real-time responsive animation
        if audioLevel <= config.noiseThreshold { // USE THE USER-CONTROLLABLE THRESHOLD!
            // Complete stillness during silence
            pulseScale = 1.0
            if animationTrigger % 10 == 0 {
                rotationAngle += 0.2
            }
        } else {
            // Fast, responsive animation
            animationPhase += 0.3 // Much faster phase changes
            rotationAngle += 1.5   // Faster rotation
            pulseScale = 1.0 + (audioLevel * 0.15) // More pronounced pulsing
        }
    }
}

// MARK: - ECG-Style Listening Overlay
struct TalkingListeningOverlayView: View {
    let audioLevelPublisher: AnyPublisher<CGFloat, Never>
    @StateObject private var appTracker = ActiveAppTracker()
    
    private var appDisplayName: String {
        if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, name.isEmpty == false {
            return name
        }
        if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String, name.isEmpty == false {
            return name
        }
        return "Fluid"
    }

    // Optional brand wordmark image from asset catalog
    private var brandWordmarkImage: NSImage? {
        // Try a few common names so you can drop in any of these
        return NSImage(named: "BrandWordmark")
            ?? NSImage(named: "FluidWordmark")
            ?? NSImage(named: "fluid_wordmark")
    }
    
    var body: some View {
        ZStack {
            // NO BACKGROUND - Using unified container from ListeningOverlayController
            
            // Centered visualizer - absolutely positioned
            TalkingAudioVisualizationView(audioLevelPublisher: audioLevelPublisher)
            
            // Brand label - absolutely positioned center-right (wordmark if available, else icon + name)
            HStack {
                Spacer()
                HStack(spacing: 4) {
                    if let wordmark = brandWordmarkImage {
                        Image(nsImage: wordmark)
                            .resizable()
                            .interpolation(.high)
                            .antialiased(true)
                            .scaledToFit()
                            .frame(height: 24)
                            .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 1)
                    } else {
                        if let nsIcon = NSApp.applicationIconImage {
                            Image(nsImage: nsIcon)
                                .resizable()
                                .interpolation(.high)
                                .antialiased(true)
                                .frame(width: 14, height: 14)
                                .cornerRadius(3)
                                .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 1)
                        }
                        Text(appDisplayName.uppercased())
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .kerning(0.5)
                            .foregroundColor(.white.opacity(0.6))
                            .shadow(color: .black.opacity(0.8), radius: 2, x: 1, y: 1)
                            .shadow(color: .black.opacity(0.6), radius: 4, x: 2, y: 2)
                            .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 0)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    Color.black.opacity(0.4),
                                    Color.black.opacity(0.6)
                                ]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(
                                    Color.white.opacity(0.1),
                                    lineWidth: 0.5
                                )
                        )
                )
                .shadow(color: Color.black.opacity(0.3), radius: 2, x: 0, y: 1)
                .padding(.trailing, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(audioLevelPublisher) { _ in }
    }
}

// MARK: - Individual Spokenly Bar
struct SpokenlyBar: View {
    let height: CGFloat
    let opacity: Double
    let index: Int
    let config: TalkingAnimationConfig
    let isActive: Bool
    
    var body: some View {
        RoundedRectangle(cornerRadius: config.barWidth / 2)
            .fill(Color.white)
            .frame(width: config.barWidth, height: height)
            .opacity(opacity)
            .shadow(color: Color.black.opacity(0.2), radius: 1, x: 0, y: 1)
    }
}

struct EnhancedTalkingListeningOverlayView: View {
    let audioLevelPublisher: AnyPublisher<CGFloat, Never>
    
    var body: some View {
        ZStack {
            EnhancedTalkingAudioVisualizationView(audioLevelPublisher: audioLevelPublisher)
        }
        .frame(width: 100, height: 32)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.08))
                .blur(radius: 6)
        )
    }
}