import AppKit
import SwiftUI

/// Visual-only cursor; native action delivery remains authoritative.
@MainActor
final class AgentCursor {
    typealias IdleHideScheduler = @MainActor (@escaping @MainActor () -> Void) -> Task<Void, Never>

    static let shared = AgentCursor(scheduleIdleHide: scheduleDefaultIdleHide)

    private var overlay: AgentCursorOverlayWindow?
    private var idleHideTask: Task<Void, Never>?
    private var idleGeneration: UInt = 0
    private let scheduleIdleHide: IdleHideScheduler

    init(scheduleIdleHide: @escaping IdleHideScheduler) {
        self.scheduleIdleHide = scheduleIdleHide
    }

    /// Never waits for the motion: the action is delivered while the cursor travels. `target`
    /// is the element's frame when known (Fitts timing, adaptive dispatch and the magnet glow
    /// assume a 24 pt box without it); a press or click plays the click effects on arrival.
    func animate(to point: CGPoint, above windowId: UInt32, motion: CursorMotion, action: ActAction? = nil, target: CGRect? = nil) {
        idleHideTask?.cancel()
        idleHideTask = nil
        idleGeneration &+= 1

        let window = ensureWindow()
        if !window.isVisible { window.orderFrontRegardless() }
        window.order(.above, relativeTo: Int(windowId))

        let renderer = AgentCursorRenderer.shared
        if !renderer.isPlaced {
            let frame = NSScreen.main?.frame ?? .zero
            renderer.setInitialPosition(CGPoint(
                x: min(max(point.x - 140, frame.minX + 2), frame.maxX - 2),
                y: min(max(point.y - 140, frame.minY + 2), frame.maxY - 2)
            ))
        }
        renderer.moveTo(
            point: point,
            target: target,
            motion: motion,
            clicks: action == .press || action == .click,
            reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )

        let generation = idleGeneration
        idleHideTask = scheduleIdleHide { [weak self, weak window] in
            guard let self, let window else { return }
            guard generation == idleGeneration, self.overlay === window else { return }

            renderer.cancelAnimation()
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            overlay = nil
            idleHideTask = nil
        }
    }

    private static func scheduleDefaultIdleHide(_ hide: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            hide()
        }
    }

    private func ensureWindow() -> AgentCursorOverlayWindow {
        if let overlay { return overlay }
        let window = AgentCursorOverlayWindow(
            contentRect: NSScreen.main?.frame ?? NSScreen.screens.first?.frame ?? .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: AgentCursorView())
        overlay = window
        return window
    }
}

/// Main-display-only, click-through overlay that can never take focus.
private final class AgentCursorOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }
}

@MainActor
private struct AgentCursorView: View {
    @Bindable private var renderer = AgentCursorRenderer.shared

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 120.0, paused: !renderer.isAnimating)) { context in
            Canvas { graphics, _ in
                renderer.tick(now: context.date.timeIntervalSinceReferenceDate)
                drawCursor(in: graphics)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    private func drawCursor(in graphics: GraphicsContext) {
        guard renderer.isPlaced else { return }
        let effects = renderer.effects
        drawEffectsUnder(effects, in: graphics)
        drawArrow(in: graphics, squish: effects.squish)
        if let ripple = effects.ripple {
            let circle = Path(ellipseIn: CGRect(x: ripple.center.x - ripple.radius, y: ripple.center.y - ripple.radius, width: ripple.radius * 2, height: ripple.radius * 2))
            graphics.stroke(circle, with: .color(Self.effectColor.opacity(ripple.alpha)), lineWidth: ripple.width)
        }
    }

    private static let fill = Color(red: 1, green: 0x78 / 255, blue: 0x18 / 255)
    /// The fill lifted 45% toward white, like cua's effect colour.
    private static let effectColor = Color(red: 1, green: 0xB5 / 255, blue: 0x80 / 255)

    private func drawEffectsUnder(_ effects: CursorEffectFrame, in graphics: GraphicsContext) {
        if let glow = effects.glow {
            graphics.fill(
                Path(ellipseIn: CGRect(x: glow.center.x - glow.radius, y: glow.center.y - glow.radius, width: glow.radius * 2, height: glow.radius * 2)),
                with: .radialGradient(Gradient(colors: [Self.effectColor.opacity(glow.alpha), Self.effectColor.opacity(0)]), center: glow.center, startRadius: 0, endRadius: glow.radius)
            )
        }
        for segment in effects.trail {
            var line = Path()
            line.move(to: segment.from)
            line.addLine(to: segment.to)
            graphics.stroke(line, with: .color(Self.effectColor.opacity(segment.alpha)), style: StrokeStyle(lineWidth: segment.width, lineCap: .round))
        }
        if let magnet = effects.magnet {
            let rect = magnet.rect.insetBy(dx: -magnetInflate, dy: -magnetInflate)
            let outline = Path(roundedRect: rect, cornerRadius: min(8, rect.width / 2, rect.height / 2))
            // Wide faint strokes stand in for a blur.
            for (width, alpha) in [(14.0, 0.10), (8.0, 0.22), (3.0, 0.9)] {
                graphics.stroke(outline, with: .color(Self.effectColor.opacity(alpha * magnet.strength)), lineWidth: width)
            }
        }
    }

    /// The arrow is drawn around its body point, 16 pt behind the hotspot; a squish scales it
    /// about the hotspot.
    private func drawArrow(in graphics: GraphicsContext, squish: Double) {
        let scale = 1 - squish
        let hotspot = renderer.hotspot
        let body = anchor(hotspot, heading: renderer.heading)
        let point = CGPoint(x: hotspot.x + (body.x - hotspot.x) * scale, y: hotspot.y + (body.y - hotspot.y) * scale)

        let radius = 22 * scale
        graphics.fill(
            Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
            with: .radialGradient(
                Gradient(colors: [Self.fill.opacity(0.55), Self.fill.opacity(0.15), Self.fill.opacity(0)]),
                center: point,
                startRadius: 0,
                endRadius: radius
            )
        )

        let transformed = Self.arrow.applying(
            CGAffineTransform(translationX: point.x, y: point.y)
                .rotated(by: CGFloat(renderer.heading + .pi))
                .scaledBy(x: scale, y: scale)
        )
        graphics.fill(
            transformed,
            with: .linearGradient(
                Gradient(colors: [
                    Color(red: 1, green: 0xD0 / 255, blue: 0x76 / 255),
                    Self.fill,
                    Color(red: 0xE8 / 255, green: 0x4A / 255, blue: 0x0C / 255),
                ]),
                startPoint: CGPoint(x: point.x + 14, y: point.y - 9),
                endPoint: CGPoint(x: point.x - 8, y: point.y + 9)
            )
        )
        graphics.stroke(transformed, with: .color(.white), lineWidth: 2)
    }

    /// Tip at (14, 0), body at the origin, corners rounded.
    private static let arrow: Path = {
        let points = [
            CGPoint(x: 14, y: 0),
            CGPoint(x: -8, y: -9),
            CGPoint(x: -3, y: 0),
            CGPoint(x: -8, y: 9),
        ]
        var shape = Path()
        for index in points.indices {
            let previous = points[(index + points.count - 1) % points.count]
            let current = points[index]
            let next = points[(index + 1) % points.count]
            let entry = CGPoint(x: current.x + (previous.x - current.x) * 0.16, y: current.y + (previous.y - current.y) * 0.16)
            let exit = CGPoint(x: current.x + (next.x - current.x) * 0.16, y: current.y + (next.y - current.y) * 0.16)
            if index == points.startIndex { shape.move(to: entry) } else { shape.addLine(to: entry) }
            shape.addQuadCurve(to: exit, control: current)
        }
        shape.closeSubpath()
        return shape
    }()
}
