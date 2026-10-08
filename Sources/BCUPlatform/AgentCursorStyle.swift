/// How the agent cursor travels to a target. Each style ports a candidate of trycua/cua's
/// cursor motion lab (`libs/cua-driver/rust/crates/cua-cursor-motion`).
public enum CursorMotionStyle: String, CaseIterable, Codable, Sendable {
	/// One confident arc with a small follow-through.
	case signatureArc = "signature_arc"
	/// An arc that lands with one soft bounce.
	case springSettle = "spring_settle"
	/// Slows near the target, then is pulled in.
	case magnetic
	/// A wide arc with a short trail.
	case cometSwoop = "comet_swoop"
	/// Careful for small targets, a swoop for long moves, a minimum-jerk reach otherwise.
	case adaptive
	/// The Dubins glide with an arrival spring.
	case classic

	/// The effects a style shows unless the selection overrides them.
	public var defaultEffects: CursorEffects {
		switch self {
		case .signatureArc: CursorEffects(glow: true, ripple: true, squish: true)
		case .springSettle: CursorEffects(glow: true, squish: true)
		case .magnetic: CursorEffects(magnet: true, ripple: true)
		case .cometSwoop: CursorEffects(trail: true, ripple: true)
		case .adaptive: CursorEffects(squish: true)
		case .classic: CursorEffects()
		}
	}
}

/// How long a move takes.
public enum CursorMotionTiming: String, CaseIterable, Codable, Sendable {
	/// The style's own timing.
	case native
	/// Fitts' law, `150 + 120 log2(D / W + 1)` ms within 300…1000, W the target's smaller side.
	case fitts
	/// Every move takes 1430 ms.
	case fixed
}

public struct CursorEffects: Codable, Equatable, Sendable {
	public static let names = ["trail", "glow", "magnet", "ripple", "squish"]

	/// A fading comet trail behind the arrow's body.
	public var trail = false
	/// A soft glow that trails the cursor and grows with speed.
	public var glow = false
	/// A glow around the target when the magnetic style locks on.
	public var magnet = false
	/// A ring that expands from the hotspot when a click lands.
	public var ripple = false
	/// A brief scale-down of the arrow when a click lands.
	public var squish = false

	public init(trail: Bool = false, glow: Bool = false, magnet: Bool = false, ripple: Bool = false, squish: Bool = false) {
		self.trail = trail
		self.glow = glow
		self.magnet = magnet
		self.ripple = ripple
		self.squish = squish
	}

	/// Sets the effect called `name`; false when there is no such effect.
	public mutating func set(_ name: String, to value: Bool) -> Bool {
		switch name {
		case "trail": trail = value
		case "glow": glow = value
		case "magnet": magnet = value
		case "ripple": ripple = value
		case "squish": squish = value
		default: return false
		}
		return true
	}
}

/// The agent cursor's motion: a style, a timing mode and the effects to paint.
public struct CursorMotion: Codable, Equatable, Sendable {
	public var style: CursorMotionStyle
	public var timing: CursorMotionTiming
	public var effects: CursorEffects

	/// `effects` defaults to the style's own.
	public init(style: CursorMotionStyle = .signatureArc, timing: CursorMotionTiming = .native, effects: CursorEffects? = nil) {
		self.style = style
		self.timing = timing
		self.effects = effects ?? style.defaultEffects
	}
}
