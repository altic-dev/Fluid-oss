import AppKit

final class ListeningOverlayController
{
    private var panel: NSPanel?
    private var asrService: ASRService
    private var line1TextField: NSTextField? // Top - faded (previous)
    private var line2TextField: NSTextField? // Bottom - bright (current)
    private var previousText: String = ""
    private var unifiedContainer: NSView?
    private var orbView: NSView?
    private var isShowingPreview: Bool = true

    init(asrService: ASRService)
    {
        self.asrService = asrService
    }

    func show(with view: NSView, showPreview: Bool = true)
    {
        // CRITICAL: Always clean up existing panel first to prevent duplicates
        if let existingPanel = panel {
            existingPanel.orderOut(nil)
            existingPanel.contentView = nil
            panel = nil
        }
        
        isShowingPreview = showPreview
        
        // Dynamic sizing based on preview state
        let width: CGFloat = 340
        let height: CGFloat = showPreview ? 100 : 90  // Compact for 2 lines
        let orbY: CGFloat = showPreview ? 40 : 10
        
        // Create fresh panel with dynamic size
        let style: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                        styleMask: style,
                        backing: .buffered,
                        defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        p.backgroundColor = .clear
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        panel = p
        
        // CRITICAL FIX: Create ONE unified container with background for both orb and text
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        container.layer?.cornerRadius = 12
        unifiedContainer = container
        
        // Create inner container for layout
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.addSubview(containerView)
        
        // Add SwiftUI hosting view to container (at top, no background)
        view.frame = NSRect(x: 0, y: orbY, width: width, height: 70)
        containerView.addSubview(view)
        orbView = view
        
        // Add text fields to container (at bottom) - only if preview enabled
        if showPreview {
            setupTranscriptionTextField(in: containerView)
        }
        
        panel?.contentView = container
        positionCenteredLower()
        
        // Set initial state for entrance animation
        container.wantsLayer = true
        container.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        container.alphaValue = 0.0
        
        // Apply initial transform: scale 0.85 and translate Y -10px
        let initialTransform = CATransform3DIdentity
        let scaledTransform = CATransform3DScale(initialTransform, 0.85, 0.85, 1.0)
        let translatedTransform = CATransform3DTranslate(scaledTransform, 0, -10, 0)
        container.layer?.transform = translatedTransform
        
        panel?.orderFrontRegardless()
        
        // Animate entrance with spring effect
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            
            // Animate to final state: scale 1.0, opacity 1.0, Y position 0
            container.animator().alphaValue = 1.0
            container.layer?.transform = CATransform3DIdentity
        })
    }

    func hide()
    {
        guard let container = unifiedContainer else {
            panel?.orderOut(nil)
            return
        }
        
        // Animate exit before hiding panel
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            
            // Animate scale down and fade out
            container.animator().alphaValue = 0.0
            let exitTransform = CATransform3DScale(CATransform3DIdentity, 0.9, 0.9, 1.0)
            container.layer?.transform = exitTransform
        }, completionHandler: {
            // Hide panel after animation completes
            self.panel?.orderOut(nil)
        })
    }

    private func activeScreen() -> NSScreen?
    {
        if let key = NSApp.keyWindow?.screen { return key }
        if let mouse = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) { return mouse }
        return NSScreen.main
    }

    private func positionCenteredLower()
    {
        guard let screen = activeScreen(), let panel else { return }
        let visible = screen.visibleFrame
        panel.layoutIfNeeded()
        let size = panel.frame.size
        let centerX = visible.midX - size.width / 2
        let bottomPadding: CGFloat = 140
        let yPosition = visible.minY + bottomPadding
        panel.setFrameOrigin(NSPoint(x: centerX.rounded(), y: yPosition.rounded()))
    }
    
    private func setupTranscriptionTextField(in containerView: NSView)
    {
        // Remove existing text fields if any
        line1TextField?.removeFromSuperview()
        line2TextField?.removeFromSuperview()
        
        // Create container for two-line scrolling layout (no background, uses unified)
        let textContainer = NSView(frame: .zero)
        textContainer.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(textContainer)
        
        // Line 1 (top) - Faded, previous
        let line1 = createTextField(alpha: 0.45, fontSize: 9, weight: .regular)
        textContainer.addSubview(line1)
        
        // Line 2 (bottom) - Bright, current
        let line2 = createTextField(alpha: 1.0, fontSize: 10, weight: .medium)
        textContainer.addSubview(line2)
        
        // Layout constraints for two-line stack (super compact)
        NSLayoutConstraint.activate([
            // Line 1 (top)
            line1.topAnchor.constraint(equalTo: textContainer.topAnchor, constant: 2),
            line1.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor, constant: 10),
            line1.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor, constant: -10),
            
            // Line 2 (bottom)
            line2.topAnchor.constraint(equalTo: line1.bottomAnchor, constant: 1),
            line2.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor, constant: 10),
            line2.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor, constant: -10),
            line2.bottomAnchor.constraint(equalTo: textContainer.bottomAnchor, constant: -2)
        ])
        
        // Position container at the bottom (super compact)
        NSLayoutConstraint.activate([
            textContainer.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
            textContainer.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
            textContainer.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -5),
            textContainer.heightAnchor.constraint(equalToConstant: 32)  // Super compact for 2 lines
        ])
        
        line1TextField = line1
        line2TextField = line2
        
        // Hide container initially
        textContainer.alphaValue = 0.0
    }
    
    private func createTextField(alpha: CGFloat, fontSize: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let field = NSTextField(frame: .zero)
        field.isEditable = false
        field.isBordered = false
        field.drawsBackground = false
        field.textColor = .white
        field.alignment = .center
        field.font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.wraps = false
        field.cell?.isScrollable = false
        field.stringValue = ""
        field.alphaValue = alpha
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }
    
    func setPreviewEnabled(_ enabled: Bool) {
        guard isShowingPreview != enabled else { return }
        isShowingPreview = enabled
        
        // Resize panel and container
        let width: CGFloat = 340
        let height: CGFloat = enabled ? 100 : 90  // Compact for 2 lines
        let orbY: CGFloat = enabled ? 40 : 10
        
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            
            if let panel = panel {
                var frame = panel.frame
                let oldHeight = frame.size.height
                frame.size.height = height
                frame.size.width = width
                frame.origin.y += (oldHeight - height) // Keep bottom aligned
                panel.animator().setFrame(frame, display: true)
            }
            
            if let container = unifiedContainer {
                container.animator().frame = NSRect(x: 0, y: 0, width: width, height: height)
            }
            
            if let orb = orbView {
                orb.animator().frame = NSRect(x: 0, y: orbY, width: width, height: 70)
            }
        })
        
        // Show/hide text fields
        if enabled {
            if line1TextField == nil, let containerView = orbView?.superview {
                setupTranscriptionTextField(in: containerView)
            }
        } else {
            line1TextField?.superview?.animator().alphaValue = 0.0
        }
    }
    
    func updateTranscriptionText(_ text: String)
    {
        guard isShowingPreview else { return } // Don't update if preview disabled
        
        guard let line1 = line1TextField,
              let line2 = line2TextField,
              let container = line2.superview else { return }
        
        if text.isEmpty {
            // Fade out container and reset
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                container.animator().alphaValue = 0.0
            })
            line1.stringValue = ""
            line2.stringValue = ""
            previousText = ""
            return
        }
        
        // Simple scrolling: show last ~100 characters across 2 lines
        let maxChars = 100
        let displayText = text.count > maxChars ? String(text.suffix(maxChars)) : text
        
        // Split into 2 lines based on space
        let words = displayText.split(separator: " ").map(String.init)
        
        if words.count <= 6 {
            // Short: only line 2
            line1.stringValue = ""
            line2.stringValue = displayText
        } else {
            // Long: split roughly in half
            let midPoint = words.count / 2
            line1.stringValue = words[..<midPoint].joined(separator: " ")
            line2.stringValue = words[midPoint...].joined(separator: " ")
        }
        
        previousText = text
        
        // Fade in container if needed
        if container.alphaValue < 1.0 {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                container.animator().alphaValue = 1.0
            })
        }
    }
}


