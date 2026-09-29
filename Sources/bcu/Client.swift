import BCUCore
import BCURuntime
import Foundation

/// `bcu <command>`: parse, reach the resident, print. Returns the process exit code.
func runClient(_ arguments: [String]) -> Int32 {
	do {
		switch try CLI.parse(arguments, stdin: { String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) }) {
		case .help(let text):
			write(text)
		case .command(let request, let json):
			let settings = try currentSettings()
			let connection = try connectOrStart(settings)
			write(try CLI.output(connection.run(settings.applying(to: request)), json: json))
		case .plain(let command, let json):
			write(try run(command, json: json, settings: currentSettings()))
		}
		return 0
	} catch {
		let failure = BCUError.normalize(error)
		FileHandle.standardError.write(Data(failure.formatted.utf8))
		return failure.exitCode
	}
}

func currentSettings() throws -> Settings {
	try Settings(environment: ProcessInfo.processInfo.environment)
}

private func write(_ text: String) {
	FileHandle.standardOutput.write(Data(text.utf8))
}

private func connectOrStart(_ settings: Settings) throws -> Connection {
	let appPath = settings.appPath
	let forwarded = settings.forwarded
	return try Client.connectOrStart(socketPath: settings.socketPath) { try launchResident(appPath: appPath, forwarded: forwarded) }
}

/// `open -n -g bcu.app --args serve`: the resident runs as the app, so macOS attributes its
/// Accessibility and Screen Recording use to bcu.app, not to the terminal that ran `bcu`.
private func launchResident(appPath: String, forwarded: [String]) throws {
	guard FileManager.default.fileExists(atPath: appPath) else {
		throw BCUError(.brokerUnavailable, "bcu.app is not installed at \(appPath). Run scripts/install.sh in the bcu checkout.")
	}
	let open = Process()
	open.executableURL = URL(filePath: "/usr/bin/open")
	open.arguments = ["-n", "-g"] + forwarded.flatMap { ["--env", $0] } + [appPath, "--args", "serve"]
	let errors = Pipe()
	open.standardError = errors
	open.standardOutput = FileHandle.nullDevice
	try open.run()
	let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
	open.waitUntilExit()
	guard open.terminationStatus == 0 else {
		throw BCUError(.brokerUnavailable, "open \(appPath) exited \(open.terminationStatus): \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
	}
}

private func run(_ command: PlainCommand, json: Bool, settings: Settings) throws -> String {
	switch command {
	case .status: try status(settings, json: json)
	case .stop: try stop(settings, json: json)
	case .doctor: try doctor(settings, json: json)
	case .setup: try setup(settings, json: json)
	}
}

private func output(_ value: JSONValue, _ text: String, json: Bool) -> String {
	json ? value.serialized() + "\n" : text + "\n"
}

private func object(_ members: [(String, JSONValue)]) -> JSONValue {
	.object(members.map { JSONMember($0.0, $0.1) })
}

private func number(_ value: Int) -> JSONValue {
	.number(Double(value))
}

private func status(_ settings: Settings, json: Bool) throws -> String {
	guard let connection = try Client.connectIfRunning(socketPath: settings.socketPath) else {
		return output(object([("running", .bool(false))]), "resident stopped", json: json)
	}
	defer { connection.close() }
	let status = connection.status
	return output(
		object([("running", .bool(true)), ("pid", number(status.pid)), ("protocolVersion", number(status.protocolVersion))]),
		"resident running · pid \(status.pid) · protocol \(status.protocolVersion)",
		json: json
	)
}

private func stop(_ settings: Settings, json: Bool) throws -> String {
	guard let status = try Client.stop(socketPath: settings.socketPath) else {
		return output(object([("stopped", .bool(true)), ("alreadyStopped", .bool(true))]), "resident already stopped", json: json)
	}
	return output(object([("stopped", .bool(true)), ("pid", number(status.pid))]), "resident stopped · pid \(status.pid)", json: json)
}

/// The resident's doctor report carries `permissions: {accessibility, screenRecording}`.
private struct Permissions: Codable {
	var accessibility: Bool
	var screenRecording: Bool

	init(report: JSONValue) throws {
		guard let permissions = report["permissions"] else { throw BCUError(.internalError, "The resident's doctor report has no permissions.") }
		self = try JSONCoding.decode(Permissions.self, from: permissions)
	}

	var line: String { "permissions: accessibility=\(accessibility) screenRecording=\(screenRecording)" }
}

private func doctor(_ settings: Settings, json: Bool) throws -> String {
	let connection = try connectOrStart(settings)
	defer { connection.close() }
	let report = try connection.send(.plain(.doctor))
	let status = connection.status
	guard case .object(let members) = report else { throw BCUError(.internalError, "The resident's doctor report is not an object.") }
	let resident = object([("pid", number(status.pid)), ("protocolVersion", number(status.protocolVersion))])
	let value = JSONValue.object([JSONMember("resident", resident)] + members + [JSONMember("config", try JSONCoding.encode(settings.config))])
	return output(value, "resident ok · pid \(status.pid) · protocol \(status.protocolVersion)\n\(try Permissions(report: report).line)", json: json)
}

/// Registers bcu.app with both privacy panes, waits for the user to switch them on, then
/// restarts the resident, because macOS caches a process's grants when it first asks.
private func setup(_ settings: Settings, json: Bool) throws -> String {
	guard isatty(STDIN_FILENO) != 0, isatty(STDERR_FILENO) != 0 else {
		throw BCUError(.permissionMissing, "bcu setup requires an interactive terminal so you can grant macOS permissions.")
	}
	let registered = try connectOrStart(settings).send(.plain(.setup))
	FileHandle.standardError.write(Data("Enable bcu in System Settings → Privacy & Security → Accessibility and Screen Recording.\nPress Enter after both switches are enabled: ".utf8))
	_ = readLine()
	_ = try Client.stop(socketPath: settings.socketPath)
	let connection = try connectOrStart(settings)
	defer { connection.close() }
	let report = try connection.send(.plain(.doctor))
	let permissions = try Permissions(report: report)
	guard permissions.accessibility, permissions.screenRecording else {
		throw BCUError(.permissionMissing, "bcu still lacks required macOS permissions: \(permissions.line).")
	}
	let value = object([("registered", registered), ("ready", .bool(true)), ("permissions", report["permissions"]!)])
	return output(value, "setup: permissions granted", json: json)
}
