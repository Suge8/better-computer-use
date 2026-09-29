import BCUCore
import BCURuntime
import Foundation

/// The environment knobs and the user config file, read the same way by the client and by
/// `bcu serve`. LaunchServices does not hand the caller's environment to the app it starts,
/// so the client forwards every `BCU_*` variable to the resident explicitly.
struct Settings {
	static let defaultAppPath = "/Applications/bcu.app"
	static let defaultIdleTimeout: Duration = .seconds(600)

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
			idleTimeout = Self.defaultIdleTimeout
		}
		config = LoadedConfig(environment: environment)
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
}

struct PartialConfig: Codable {
	var headless: Bool?
	var cursor_overlay: Bool?

	/// A config object, or its `computer_use` member when it has one; unreadable values are ignored.
	init(_ raw: JSONValue) {
		let source = raw["computer_use"].flatMap { if case .object = $0 { $0 } else { nil } } ?? raw
		headless = source["headless"].flatMap(parseBoolean)
		cursor_overlay = source["cursor_overlay"].flatMap(parseBoolean)
	}

	init(headless: String?, cursorOverlay: String?) {
		self.headless = headless.flatMap { parseBoolean(.string($0)) }
		self.cursor_overlay = cursorOverlay.flatMap { parseBoolean(.string($0)) }
	}

	func applied(to config: Config) -> Config {
		Config(headless: headless ?? config.headless, cursor_overlay: cursor_overlay ?? config.cursor_overlay)
	}
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

	init(environment: [String: String]) {
		let home = environment["HOME"] ?? NSHomeDirectory()
		let file = Self.read("\(home)/.config/bcu/config.json")
		env = PartialConfig(headless: environment["BCU_HEADLESS"], cursorOverlay: environment["BCU_CURSOR_OVERLAY"])
		sources = [file]
		config = env.applied(to: (file.values ?? PartialConfig(.null)).applied(to: Config()))
	}

	private static func read(_ path: String) -> ConfigSource {
		guard FileManager.default.fileExists(atPath: path) else { return ConfigSource(path: path, exists: false) }
		do {
			let text = try String(contentsOfFile: path, encoding: .utf8)
			return ConfigSource(path: path, exists: true, values: PartialConfig(try JSONValue(parsing: text)))
		} catch {
			return ConfigSource(path: path, exists: true, error: "\(error)")
		}
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
