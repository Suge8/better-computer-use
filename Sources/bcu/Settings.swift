import BCUCore
import BCUPlatform
import BCURuntime
import Foundation

/// The environment knobs and the user config file, read the same way by the client and by
/// `bcu serve`. LaunchServices does not hand the caller's environment to the app it starts,
/// so the client forwards every `BCU_*` variable to the resident explicitly.
struct Settings {
	let socketPath: String
	let idleTimeout: Duration
	/// `BCU_APP_PATH`, else the app this executable sits in; nil for a bare executable.
	let appPath: String?
	let config: LoadedConfig
	/// `NAME=value` for every `BCU_*` variable, for `open --env`.
	let forwarded: [String]

	init(environment: [String: String]) throws {
		socketPath = environment["BCU_SOCKET_PATH"] ?? RuntimePaths.socket
		appPath = environment["BCU_APP_PATH"] ?? App.containing
		if let idle = environment["BCU_IDLE_MS"] {
			guard let milliseconds = Int(idle), milliseconds >= 0 else {
				throw BCUError(.invalidArguments, "BCU_IDLE_MS must be a whole number of milliseconds, not '\(idle)'.")
			}
			idleTimeout = .milliseconds(milliseconds)
		} else {
			idleTimeout = Server.defaultIdleTimeout
		}
		config = try LoadedConfig(environment: environment)
		forwarded = environment.filter { $0.key.hasPrefix("BCU_") }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
	}

	/// The motion of the agent cursor that draws pointer actions, or nil when it is off;
	/// headless forbids those actions, so it never shows then.
	var agentCursor: CursorMotion? {
		config.config.cursor_overlay && !config.config.headless ? config.config.cursor_motion : nil
	}

	/// A configured headless mode tightens every act-ui; nothing loosens it again.
	func applying(to request: CommandRequest) -> CommandRequest {
		guard config.config.headless, case .actUi(var params) = request else { return request }
		params.headless = true
		return .actUi(params)
	}
}

struct Config: Codable {
	var headless = false
	var cursor_overlay = true
	var cursor_motion = CursorMotion()
}

/// What one source, the config file or the environment, sets. A wrong value, an unknown key
/// or a file that is not JSON is refused, naming what is allowed: a config that is silently
/// half-applied looks like a bcu bug.
struct PartialConfig: Codable {
	var headless: Bool?
	var cursor_overlay: Bool?
	var cursor_motion: PartialCursorMotion?

	init(_ raw: JSONValue, path: String) throws {
		let members = try object(raw, name: path, keys: ["headless", "cursor_overlay", "cursor_motion"])
		headless = try members["headless"].map { try flag($0, name: "headless in \(path)") }
		cursor_overlay = try members["cursor_overlay"].map { try flag($0, name: "cursor_overlay in \(path)") }
		cursor_motion = try members["cursor_motion"].map { try PartialCursorMotion($0, path: path) }
	}

	init(environment: [String: String]) throws {
		headless = try environment["BCU_HEADLESS"].map { try flag(.string($0), name: "BCU_HEADLESS") }
		cursor_overlay = try environment["BCU_CURSOR_OVERLAY"].map { try flag(.string($0), name: "BCU_CURSOR_OVERLAY") }
		cursor_motion = try PartialCursorMotion(environment: environment)
	}

	private init() {}

	static let empty = PartialConfig()

	/// `other`'s fields over this source's.
	func overridden(by other: PartialConfig) -> PartialConfig {
		var merged = other
		merged.headless = other.headless ?? headless
		merged.cursor_overlay = other.cursor_overlay ?? cursor_overlay
		merged.cursor_motion = cursor_motion.map { $0.overridden(by: other.cursor_motion) } ?? other.cursor_motion
		return merged
	}

	func applied(to config: Config) -> Config {
		Config(
			headless: headless ?? config.headless,
			cursor_overlay: cursor_overlay ?? config.cursor_overlay,
			cursor_motion: cursor_motion?.applied(to: config.cursor_motion) ?? config.cursor_motion
		)
	}
}

/// The fields of `cursor_motion` that a source sets. Effects no source sets keep the default
/// of the style in effect, whichever source chose it.
struct PartialCursorMotion: Codable {
	var style: CursorMotionStyle?
	var timing: CursorMotionTiming?
	var effects: [String: Bool]?

	init(_ raw: JSONValue, path: String) throws {
		let members = try object(raw, name: "cursor_motion in \(path)", keys: ["style", "timing", "effects"])
		style = try members["style"].map { try choice($0, name: "cursor_motion.style in \(path)") }
		timing = try members["timing"].map { try choice($0, name: "cursor_motion.timing in \(path)") }
		effects = try members["effects"].map { raw in
			try object(raw, name: "cursor_motion.effects in \(path)", keys: CursorEffects.names).reduce(into: [:]) { effects, effect in
				effects[effect.key] = try flag(effect.value, name: "cursor_motion.effects.\(effect.key) in \(path)")
			}
		}
	}

	/// `BCU_CURSOR_MOTION_STYLE`, `BCU_CURSOR_MOTION_TIMING`, and `BCU_CURSOR_MOTION_EFFECTS` as
	/// `name=on,name=off`; nil when none is set.
	init?(environment: [String: String]) throws {
		let style = environment["BCU_CURSOR_MOTION_STYLE"], timing = environment["BCU_CURSOR_MOTION_TIMING"], effects = environment["BCU_CURSOR_MOTION_EFFECTS"]
		guard style != nil || timing != nil || effects != nil else { return nil }
		self.style = try style.map { try choice(.string($0), name: "BCU_CURSOR_MOTION_STYLE") }
		self.timing = try timing.map { try choice(.string($0), name: "BCU_CURSOR_MOTION_TIMING") }
		self.effects = try effects.map { list in
			try list.split(separator: ",").reduce(into: [:]) { effects, item in
				let parts = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
				guard parts.count == 2 else { throw configError("BCU_CURSOR_MOTION_EFFECTS takes name=on|off items separated by commas, not '\(item)'.") }
				guard CursorEffects.names.contains(parts[0]) else { throw configError("BCU_CURSOR_MOTION_EFFECTS names '\(parts[0])'; use \(CursorEffects.names.joined(separator: ", ")).") }
				effects[parts[0]] = try flag(.string(parts[1]), name: "BCU_CURSOR_MOTION_EFFECTS \(parts[0])")
			}
		}
	}

	func overridden(by other: PartialCursorMotion?) -> PartialCursorMotion {
		guard let other else { return self }
		var merged = other
		merged.style = other.style ?? style
		merged.timing = other.timing ?? timing
		merged.effects = (effects ?? [:]).merging(other.effects ?? [:]) { $1 }
		return merged
	}

	func applied(to motion: CursorMotion) -> CursorMotion {
		let style = style ?? motion.style
		var effects = style.defaultEffects
		for (name, value) in self.effects ?? [:] { _ = effects.set(name, to: value) }
		return CursorMotion(style: style, timing: timing ?? motion.timing, effects: effects)
	}
}

private func object(_ value: JSONValue, name: String, keys: [String]) throws -> [String: JSONValue] {
	guard case .object(let members) = value else { throw configError("\(name) is \(value.serialized()), not an object of \(keys.joined(separator: ", ")).") }
	if let unknown = members.keys.sorted().first(where: { !keys.contains($0) }) {
		throw configError("\(name) has the key '\(unknown)' that is not a setting; use \(keys.joined(separator: ", ")).")
	}
	return members
}

private func choice<T: RawRepresentable & CaseIterable>(_ value: JSONValue, name: String) throws -> T where T.RawValue == String {
	guard let parsed = value.string.flatMap(T.init(rawValue:)) else {
		throw configError("\(name) is \(described(value)), not one of \(T.allCases.map(\.rawValue).joined(separator: ", ")).")
	}
	return parsed
}

private func flag(_ value: JSONValue, name: String) throws -> Bool {
	switch value {
	case .bool(let flag): return flag
	case .number(1): return true
	case .number(0): return false
	case .string(let text):
		let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		if ["1", "true", "yes", "on", "enabled"].contains(normalized) { return true }
		if ["0", "false", "no", "off", "disabled"].contains(normalized) { return false }
	default: break
	}
	throw configError("\(name) is \(described(value)), not a boolean (true/false, on/off, yes/no, 1/0, enabled/disabled).")
}

private func described(_ value: JSONValue) -> String {
	value.string.map { "'\($0)'" } ?? value.serialized()
}

private func configError(_ message: String) -> BCUError {
	BCUError(.invalidArguments, message, recovery: "Correct ~/.config/bcu/config.json or the BCU_* variable, then retry; 'bcu stop' makes the next command start the resident with it.")
}

struct ConfigSource: Codable {
	var path: String
	var exists: Bool
	var values: PartialConfig?
}

/// The effective config and what each source set; `bcu doctor --json` prints it as is.
struct LoadedConfig: Codable {
	var config: Config
	var sources: [ConfigSource]
	var env: PartialConfig

	init(environment: [String: String]) throws {
		let home = environment["HOME"] ?? NSHomeDirectory()
		let file = try Self.read("\(home)/.config/bcu/config.json")
		env = try PartialConfig(environment: environment)
		sources = [file]
		config = (file.values ?? .empty).overridden(by: env).applied(to: Config())
	}

	private static func read(_ path: String) throws -> ConfigSource {
		guard let data = FileManager.default.contents(atPath: path) else { return ConfigSource(path: path, exists: false) }
		let json: JSONValue
		do {
			json = try JSONValue(parsing: String(decoding: data, as: UTF8.self))
		} catch DecodingError.dataCorrupted(let context) {
			let reason = (context.underlyingError as NSError?)?.userInfo["NSDebugDescription"] as? String ?? context.debugDescription
			throw configError("\(path) is not valid JSON: \(reason)")
		}
		return ConfigSource(path: path, exists: true, values: try PartialConfig(json, path: path))
	}
}
