import BCUCore
import BCUPlatform
import BCURuntime
import Foundation

/// The environment knobs and the user config file, read the same way by the client and by
/// `bcu serve`. LaunchServices does not hand the caller's environment to the app it starts,
/// so the client forwards every `BCU_*` variable to the resident explicitly.
struct Settings {
	/// Also the default of scripts/install.sh: the script decides where the app goes and the
	/// client where to launch it from, and a client built with `swift build` sits in no app.
	static let defaultAppPath = "/Applications/bcu.app"

	let socketPath: String
	let idleTimeout: Duration
	let appPath: String
	let config: LoadedConfig
	/// `NAME=value` for every `BCU_*` variable, for `open --env`.
	let forwarded: [String]

	init(environment: [String: String]) throws {
		socketPath = environment["BCU_SOCKET_PATH"] ?? RuntimePaths.socket
		appPath = environment["BCU_APP_PATH"] ?? Self.defaultAppPath
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

	/// The agent cursor draws pointer actions; headless forbids them, so it never shows then.
	var showsAgentCursor: Bool { config.config.cursor_overlay && !config.config.headless }

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

struct PartialConfig: Codable {
	var headless: Bool?
	var cursor_overlay: Bool?
	var cursor_motion: PartialCursorMotion?

	/// A config object, or its `computer_use` member when it has one. Unreadable `headless` and
	/// `cursor_overlay` values are ignored; a wrong `cursor_motion` is refused, naming the
	/// values it accepts.
	init(_ raw: JSONValue, path: String) throws {
		let source = raw["computer_use"].flatMap { if case .object = $0 { $0 } else { nil } } ?? raw
		headless = source["headless"].flatMap(parseBoolean)
		cursor_overlay = source["cursor_overlay"].flatMap(parseBoolean)
		cursor_motion = try source["cursor_motion"].map { try PartialCursorMotion($0, path: path) }
	}

	init(environment: [String: String]) throws {
		headless = environment["BCU_HEADLESS"].flatMap { parseBoolean(.string($0)) }
		cursor_overlay = environment["BCU_CURSOR_OVERLAY"].flatMap { parseBoolean(.string($0)) }
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
		guard case .object(let members) = raw else { throw motionError("cursor_motion in \(path) is not an object; it takes style, timing and effects.") }
		for key in members.keys where !["style", "timing", "effects"].contains(key) {
			throw motionError("cursor_motion.\(key) in \(path) is not a setting; use style, timing or effects.")
		}
		style = try members["style"].map { try parse($0, as: CursorMotionStyle.self, name: "cursor_motion.style in \(path)") }
		timing = try members["timing"].map { try parse($0, as: CursorMotionTiming.self, name: "cursor_motion.timing in \(path)") }
		guard let raw = members["effects"] else { return }
		guard case .object(let flags) = raw else { throw motionError("cursor_motion.effects in \(path) is not an object of effect names to booleans.") }
		effects = try flags.reduce(into: [:]) { effects, flag in
			effects[flag.key] = try parseEffect(flag.key, flag.value, name: "cursor_motion.effects.\(flag.key) in \(path)")
		}
	}

	/// `BCU_CURSOR_MOTION_STYLE`, `BCU_CURSOR_MOTION_TIMING`, and `BCU_CURSOR_MOTION_EFFECTS` as
	/// `name=on,name=off`; nil when none is set.
	init?(environment: [String: String]) throws {
		let style = environment["BCU_CURSOR_MOTION_STYLE"], timing = environment["BCU_CURSOR_MOTION_TIMING"], effects = environment["BCU_CURSOR_MOTION_EFFECTS"]
		guard style != nil || timing != nil || effects != nil else { return nil }
		self.style = try style.map { try parse(.string($0), as: CursorMotionStyle.self, name: "BCU_CURSOR_MOTION_STYLE") }
		self.timing = try timing.map { try parse(.string($0), as: CursorMotionTiming.self, name: "BCU_CURSOR_MOTION_TIMING") }
		self.effects = try effects.map { list in
			try list.split(separator: ",").reduce(into: [:]) { effects, item in
				let parts = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
				guard parts.count == 2 else { throw motionError("BCU_CURSOR_MOTION_EFFECTS takes name=on|off items separated by commas, not '\(item)'.") }
				effects[parts[0]] = try parseEffect(parts[0], .string(parts[1]), name: "BCU_CURSOR_MOTION_EFFECTS \(parts[0])")
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

private func parse<T: RawRepresentable & CaseIterable>(_ value: JSONValue, as _: T.Type, name: String) throws -> T where T.RawValue == String {
	let allowed = T.allCases.map(\.rawValue).joined(separator: ", ")
	guard let text = value.string else { throw motionError("\(name) is \(value.serialized()), not one of \(allowed).") }
	guard let parsed = T(rawValue: text) else { throw motionError("\(name) is '\(text)', not one of \(allowed).") }
	return parsed
}

private func parseEffect(_ name: String, _ value: JSONValue, name origin: String) throws -> Bool {
	guard CursorEffects.names.contains(name) else {
		throw motionError("\(origin): '\(name)' is not an effect; use \(CursorEffects.names.joined(separator: ", ")).")
	}
	guard let flag = parseBoolean(value) else {
		throw motionError("\(origin) is \(value.string.map { "'\($0)'" } ?? value.serialized()), not a boolean (true/false, on/off, yes/no, 1/0).")
	}
	return flag
}

private func motionError(_ message: String) -> BCUError {
	BCUError(.invalidArguments, message, recovery: "Correct cursor_motion in ~/.config/bcu/config.json or the BCU_CURSOR_MOTION_* variables, then retry; 'bcu stop' makes the next command start the resident with it.")
}

struct ConfigSource: Codable {
	var path: String
	var exists: Bool
	var values: PartialConfig?
	var error: String?
}

/// The effective config, where each part came from, and why a file was ignored; `bcu doctor
/// --json` prints it as is.
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
		guard FileManager.default.fileExists(atPath: path) else { return ConfigSource(path: path, exists: false) }
		let json: JSONValue
		do {
			json = try JSONValue(parsing: try String(contentsOfFile: path, encoding: .utf8))
		} catch {
			return ConfigSource(path: path, exists: true, error: "\(error)")
		}
		return ConfigSource(path: path, exists: true, values: try PartialConfig(json, path: path))
	}
}

private func parseBoolean(_ value: JSONValue) -> Bool? {
	switch value {
	case .bool(let flag): return flag
	case .number(1): return true
	case .number(0): return false
	case .string(let text):
		let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		if ["1", "true", "yes", "on", "enabled"].contains(normalized) { return true }
		if ["0", "false", "no", "off", "disabled"].contains(normalized) { return false }
		return nil
	default: return nil
	}
}
