import SwiftUI
import PowerCuffCore

enum Palette {
    static let ok = Color(red: 0.20, green: 0.78, blue: 0.45)
    static let warn = Color(red: 0.98, green: 0.70, blue: 0.15)
    static let hot = Color(red: 0.96, green: 0.30, blue: 0.28)
    static let accent = Color(red: 0.35, green: 0.62, blue: 1.0)

    static func level(watts: Double, cap: Double) -> Color {
        watts > cap ? hot : (watts > cap * 0.9 ? warn : ok)
    }
}

// MARK: - Liquid Glass

extension View {
    /// Liquid Glass on macOS 26+, a thin material before that.
    @ViewBuilder
    func glass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            let base = Glass.regular
            let tinted = tint.map { base.tint($0) } ?? base
            self.glassEffect(interactive ? tinted.interactive() : tinted, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay { if let tint { shape.fill(tint.opacity(0.12)) } }
                .overlay { shape.stroke(.white.opacity(0.10), lineWidth: 0.5) }
        }
    }

    func glassCard(cornerRadius: CGFloat = 22, tint: Color? = nil) -> some View {
        glass(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), tint: tint)
    }
}

/// Groups glass shapes so they blend and render as one pass.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing, content: content)
        } else {
            content()
        }
    }
}

/// Soft colour wash behind the glass; it is what the glass refracts. Single hue (the power-state tint), so no purple from mixing.
/// Radial gradients rather than `.blur`: blurs are rasterised on the CPU inside a menu-bar popover.
struct AmbientBackground: View {
    let tint: Color

    private func glow(_ color: Color, _ radius: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [color, color.opacity(0)], center: .center, startRadius: 0, endRadius: radius))
            .frame(width: radius * 2, height: radius * 2)
    }

    var body: some View {
        ZStack {
            glow(tint.opacity(0.55), 230).offset(x: -70, y: -230)
            glow(tint.opacity(0.30), 210).offset(x: 150, y: 40)
            glow(tint.opacity(0.26), 230).offset(x: -120, y: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(.smooth(duration: 1.2), value: tint)
        .allowsHitTesting(false)
    }
}

// MARK: - Gauge

/// The 270° ring, drawn with Core Animation layers. SwiftUI would re-render an animated ring on the CPU
/// every frame (about 40 % of a core here); CA animations run in the render server and cost the app nothing.
private struct ArcRing: NSViewRepresentable {
    var fraction: Double        // 0...1 filled
    var capFraction: Double     // 0...1 marker position
    var tint: Color
    var duration: Double
    var lineWidth: CGFloat

    func makeNSView(context: Context) -> ArcRingView { ArcRingView(lineWidth: lineWidth) }

    func updateNSView(_ v: ArcRingView, context: Context) {
        v.apply(fraction: fraction, capFraction: capFraction, tint: NSColor(tint), duration: duration)
    }
}

final class ArcRingView: NSView {
    private let track = CAShapeLayer(), glow = CAShapeLayer(), fill = CAShapeLayer()
    private let tickHost = CALayer(), tick = CALayer()
    private let lineWidth: CGFloat
    private var tint = NSColor.systemBlue
    private var built = false

    init(lineWidth: CGFloat) {
        self.lineWidth = lineWidth
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        for l in [track, glow, fill] {
            l.fillColor = nil
            l.lineCap = .round
            layer?.addSublayer(l)
        }
        track.lineWidth = lineWidth
        glow.lineWidth = lineWidth + 8
        fill.lineWidth = lineWidth
        tick.cornerRadius = 1.5
        tickHost.addSublayer(tick)
        layer?.addSublayer(tickHost)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let r = (min(bounds.width, bounds.height) - lineWidth) / 2
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = CGMutablePath()
        path.addArc(center: c, radius: r, startAngle: .pi * 0.75, endAngle: .pi * 2.25, clockwise: false)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for l in [track, glow, fill] { l.bounds = CGRect(origin: .zero, size: bounds.size); l.position = CGPoint(x: bounds.midX, y: bounds.midY); l.path = path }
        // Never assign `frame` to a layer that carries a transform (undefined); use bounds + position.
        tickHost.bounds = CGRect(origin: .zero, size: bounds.size)
        tickHost.position = CGPoint(x: bounds.midX, y: bounds.midY)
        tick.bounds = CGRect(x: 0, y: 0, width: lineWidth + 10, height: 3)
        tick.position = CGPoint(x: bounds.midX + r, y: bounds.midY)
        CATransaction.commit()
        built = true
        refreshColors()
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshColors() }

    private func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            track.strokeColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
            tick.backgroundColor = NSColor.labelColor.cgColor
            CATransaction.commit()
        }
    }

    func apply(fraction: Double, capFraction: Double, tint: NSColor, duration: Double) {
        let f = CGFloat(min(max(fraction, 0.004), 1))
        let angle = CGFloat(capFraction.isFinite ? min(max(capFraction, 0), 1) : 0) * .pi * 1.5
        CATransaction.begin()
        CATransaction.setDisableActions(!built)          // first layout: no fly-in
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        fill.strokeEnd = f
        glow.strokeEnd = f
        fill.strokeColor = tint.cgColor
        glow.strokeColor = tint.withAlphaComponent(0.22).cgColor
        tickHost.transform = CATransform3DMakeRotation(angle + .pi * 0.75, 0, 0, 1)
        CATransaction.commit()
        self.tint = tint
    }
}

/// 270° gauge with a tick at the cap.
struct GaugeView: View {
    let watts: Double
    let cap: Double
    let scaleMax: Double
    let tint: Color
    let caption: String
    var duration: Double = 0.8

    private let lineWidth: CGFloat = 13
    private let size: CGFloat = 150

    private func fraction(_ v: Double) -> Double { min(max(v / scaleMax, 0), 1) }

    var body: some View {
        ZStack {
            ArcRing(fraction: fraction(watts), capFraction: fraction(cap), tint: tint,
                    duration: duration, lineWidth: lineWidth)
                .frame(width: size, height: size)
            VStack(spacing: 0) {
                Text("\(Int(watts.rounded()))")
                    .font(.system(size: 50, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("watts").font(.callout).foregroundStyle(.secondary)
                Text(caption).font(.caption).foregroundStyle(.secondary).padding(.top, 2)
            }
            .offset(y: 4)
        }
        .frame(width: size, height: size)
        .padding(4)
    }
}

// MARK: - Tile

struct Tile: View {
    let title: String
    let value: String
    var sub: String? = nil
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.system(.callout, design: .rounded, weight: .semibold)).foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.7).monospacedDigit()
            Text(sub ?? " ").font(.caption2).foregroundStyle(.tertiary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .glassCard(cornerRadius: 14)
    }
}
