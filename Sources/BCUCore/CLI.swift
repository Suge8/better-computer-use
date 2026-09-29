/// The `bcu` command surface: argument parsing, help and result output. Running a command
/// happens elsewhere; this turns argv and stdin into a request and a result into stdout.

public enum PlainCommand: String, CaseIterable, Sendable {
	case status, doctor, setup, stop

	var summary: String {
		switch self {
		case .status: "Report resident process status without starting it."
		case .doctor: "Start and diagnose the resident process, permissions and config."
		case .setup: "Register and verify macOS permissions."
		case .stop: "Stop the resident process if it is running."
		}
	}
}

public enum Invocation: Sendable, Equatable {
	/// Help text, exactly as written to stdout.
	case help(String)
	case command(CommandRequest, json: Bool)
	case plain(PlainCommand, json: Bool)
}

private enum OptionKind {
	case string([String]?)
	case integer
	case flag
}

private struct OptionSpec {
	let flag: String
	let key: String
	let kind: OptionKind
	let doc: String
}

private enum OptionValue {
	case string(String)
	case integer(Int)
	case flag
}

private struct ParsedOptions {
	var values: [String: OptionValue] = [:]
	var positionals: [String] = []

	func raw(_ key: String) -> String? {
		if case .string(let value) = values[key] { return value }
		return nil
	}

	func integer(_ key: String) -> Int? {
		if case .integer(let value) = values[key] { return value }
		return nil
	}

	func flag(_ key: String) -> Bool? {
		if case .flag = values[key] { return true }
		return nil
	}

	/// The trimmed value, or nil when it is absent or blank.
	func trimmed(_ key: String) -> String? {
		Text.trimmedOrNil(raw(key))
	}

	func required(_ key: String, _ flag: String) throws -> String {
		guard let value = trimmed(key) else { throw invalid("Option '\(flag)' is required.") }
		return value
	}

	func noPositionals() throws {
		if let first = positionals.first { throw invalid("Unexpected argument '\(first)'.") }
	}
}

private let stateOption = OptionSpec(flag: "--state", key: "stateId", kind: .string(nil), doc: "stateId from observe-ui (required)")
private let refOption = OptionSpec(flag: "--ref", key: "ref", kind: .string(nil), doc: "element ref from the same state, e.g. @e12 (required)")
private let imageOption = OptionSpec(flag: "--image", key: "image", kind: .string(ImageMode.allCases.map(\.rawValue)), doc: "write a screenshot artifact (default never)")
private let timeoutOption = OptionSpec(flag: "--timeout", key: "timeoutMs", kind: .integer, doc: "condition timeout in ms (default 10000, max 60000)")
private let scopeOption = OptionSpec(flag: "--scope", key: "scope", kind: .string(nil), doc: "limit the condition to this element subtree, e.g. @e12")

private struct CommandSpec {
	let summary: String
	var arguments: String?
	let options: [OptionSpec]
}

private let commandSpecs: [CommandName: CommandSpec] = [
	.findRoots: CommandSpec(summary: "List controllable roots: windows, sheets, dialogs and open menus.", options: [
		OptionSpec(flag: "--query", key: "query", kind: .string(nil), doc: "match app name or window title"),
		OptionSpec(flag: "--app", key: "app", kind: .string(nil), doc: "restrict to one app name or bundle id; an exact name excludes longer names containing it"),
		OptionSpec(flag: "--bundle-id", key: "bundleId", kind: .string(nil), doc: "restrict to one exact bundle id"),
		OptionSpec(flag: "--pid", key: "pid", kind: .integer, doc: "restrict to one process id"),
		OptionSpec(flag: "--kind", key: "kind", kind: .string(RootKind.allCases.map(\.rawValue)), doc: "restrict to one root kind; menubar roots are listed only when this or an app names them"),
	]),
	.observeUi: CommandSpec(summary: "Observe one root and return a stateId with the projected element tree.", options: [
		OptionSpec(flag: "--app", key: "app", kind: .string(nil), doc: "app name or bundle id"),
		OptionSpec(flag: "--window-title", key: "windowTitle", kind: .string(nil), doc: "exact or partial window title"),
		OptionSpec(flag: "--root", key: "root", kind: .string(nil), doc: "@r ref from find-roots, or a numeric window id"),
		OptionSpec(flag: "--mode", key: "mode", kind: .string(ObserveMode.allCases.map(\.rawValue)), doc: "semantic: accessibility only (default); fused: also capture an image and OCR"),
		imageOption,
		OptionSpec(flag: "--read-text", key: "readText", kind: .string(ReadTextMode.allCases.map(\.rawValue)), doc: "OCR policy; auto (default) reads the screen only when the root exposes almost no accessibility content"),
	]),
	.searchUi: CommandSpec(summary: "Search the saved outline of one state, including elements the view folded away.", options: [
		stateOption,
		OptionSpec(flag: "--text", key: "text", kind: .string(nil), doc: "substring of any name, value or OCR text"),
		OptionSpec(flag: "--role", key: "role", kind: .string(nil), doc: "role word, e.g. button, textfield, row"),
		OptionSpec(flag: "--action", key: "action", kind: .string(nil), doc: "capability, e.g. press, setText, scroll"),
		OptionSpec(flag: "--limit", key: "limit", kind: .integer, doc: "maximum matches to return (default 12, max 50)"),
	]),
	.expandUi: CommandSpec(summary: "Expand one element of a saved state, walking the live UI when the subtree was cut short.", options: [
		stateOption,
		refOption,
		OptionSpec(flag: "--depth", key: "depth", kind: .integer, doc: "levels to unfold below the element (default 3, max 8)"),
	]),
	.inspectUi: CommandSpec(summary: "Print every raw accessibility field of one element, including the ones the projection hides.", options: [stateOption, refOption]),
	.actUi: CommandSpec(summary: "Run a checked action array from stdin against one state and return the successor state.", arguments: "-", options: [
		stateOption,
		OptionSpec(flag: "--headless", key: "headless", kind: .flag, doc: "never activate, focus or move the pointer physically"),
		OptionSpec(flag: "--foreground", key: "foreground", kind: .flag, doc: "start in the foreground: activate the app and use real input"),
		imageOption,
		OptionSpec(flag: "--expect-text", key: "expectText", kind: .string(nil), doc: "postcondition: this text must appear"),
		OptionSpec(flag: "--expect-role", key: "expectRole", kind: .string(nil), doc: "postcondition: an element with this role must appear"),
		OptionSpec(flag: "--expect-value", key: "expectValue", kind: .string(nil), doc: "postcondition: an element must hold this exact value"),
		OptionSpec(flag: "--expect-gone", key: "expectGone", kind: .flag, doc: "invert the postcondition: it must disappear"),
		scopeOption,
		timeoutOption,
	]),
	.readText: CommandSpec(summary: "Read the full text of one element, a slice at a time.", options: [
		stateOption,
		refOption,
		OptionSpec(flag: "--offset", key: "offset", kind: .integer, doc: "first character to read (default 0)"),
		OptionSpec(flag: "--limit", key: "limit", kind: .integer, doc: "characters to read (default 4000, max 100000)"),
	]),
	.waitFor: CommandSpec(summary: "Wait for text or a role to appear or disappear, then return the successor state.", options: [
		stateOption,
		OptionSpec(flag: "--text", key: "text", kind: .string(nil), doc: "text that must appear"),
		OptionSpec(flag: "--role", key: "role", kind: .string(nil), doc: "role word that must appear"),
		scopeOption,
		OptionSpec(flag: "--gone", key: "gone", kind: .flag, doc: "wait for the condition to disappear instead"),
		timeoutOption,
	]),
]

private let helpColumn = 26

public enum CLI {
	/// Parses argv; `stdin` is read only by act-ui, after its options are known to be valid.
	public static func parse(_ args: [String], stdin: () throws -> String) throws -> Invocation {
		let json = args.contains("--json")
		let help = args.contains("--help") || args.contains("-h")
		let rest = args.filter { $0 != "--json" && $0 != "--help" && $0 != "-h" }
		guard let command = rest.first else { return .help(overviewHelp() + "\n") }
		if let name = CommandName(rawValue: command) {
			if help { return .help(commandHelp(name) + "\n") }
			return .command(try request(name, parseOptions(Array(rest.dropFirst()), commandSpecs[name]!.options), stdin: stdin), json: json)
		}
		if let plain = PlainCommand(rawValue: command) {
			if help { return .help("bcu \(plain.rawValue)\n\n\(plain.summary)\n\nOptions:\n  \(Text.padEnd("--json", helpColumn))emit one JSON object on stdout\n") }
			if rest.count > 1 { throw invalid("\(plain.rawValue) accepts no options except --json.") }
			return .plain(plain, json: json)
		}
		if help { return .help(overviewHelp() + "\n") }
		throw invalid("Unknown command '\(command)'. Run 'bcu --help'.")
	}

	/// What a successful command writes to stdout.
	public static func output(_ result: CommandResult, json: Bool) throws -> String {
		if json { return try result.json().serialized() + "\n" }
		let text = try render(result)
		return text.isEmpty ? "" : Text.trimEnd(text) + "\n"
	}
}

private func parseOptions(_ args: [String], _ specs: [OptionSpec]) throws -> ParsedOptions {
	var parsed = ParsedOptions()
	var index = 0
	while index < args.count {
		let argument = args[index]
		index += 1
		guard argument.hasPrefix("--") else {
			parsed.positionals.append(argument)
			continue
		}
		guard let spec = specs.first(where: { $0.flag == argument }) else { throw invalid("Unknown option '\(argument)'.") }
		if parsed.values[spec.key] != nil { throw invalid("Option '\(argument)' may be supplied only once.") }
		if case .flag = spec.kind {
			parsed.values[spec.key] = .flag
			continue
		}
		guard index < args.count, !args[index].hasPrefix("--") else { throw invalid("Option '\(argument)' requires a value.") }
		let raw = args[index]
		index += 1
		switch spec.kind {
		case .integer:
			// Decimal digits only: a count, an id or milliseconds is never signed, fractional or hex.
			guard !raw.isEmpty, raw.allSatisfy(\.isASCIIDigit), let value = Int(raw) else { throw invalid("Option '\(argument)' requires a non-negative integer.") }
			parsed.values[spec.key] = .integer(value)
		case .string(let allowed):
			if let allowed, !allowed.contains(raw) { throw invalid("Option '\(argument)' must be one of: \(allowed.joined(separator: ", ")).") }
			parsed.values[spec.key] = .string(raw)
		case .flag:
			break
		}
	}
	return parsed
}

private func request(_ name: CommandName, _ parsed: ParsedOptions, stdin: () throws -> String) throws -> CommandRequest {
	switch name {
	case .findRoots:
		try parsed.noPositionals()
		return .findRoots(FindParams(query: parsed.raw("query"), app: parsed.raw("app"), bundleId: parsed.raw("bundleId"), pid: parsed.integer("pid"), kind: parsed.raw("kind").flatMap(RootKind.init(rawValue:))))
	case .observeUi:
		try parsed.noPositionals()
		return .observeUi(ObserveParams(
			app: parsed.raw("app"), windowTitle: parsed.raw("windowTitle"), root: parsed.raw("root"),
			mode: parsed.raw("mode").flatMap(ObserveMode.init(rawValue:)), image: parsed.raw("image").flatMap(ImageMode.init(rawValue:)),
			readText: parsed.raw("readText").flatMap(ReadTextMode.init(rawValue:))
		))
	case .searchUi:
		try parsed.noPositionals()
		_ = try parsed.required("stateId", "--state")
		return .searchUi(SearchUiParams(stateId: parsed.raw("stateId")!, text: parsed.raw("text"), role: parsed.raw("role"), action: parsed.raw("action"), limit: parsed.integer("limit")))
	case .expandUi:
		try parsed.noPositionals()
		return .expandUi(ExpandUiParams(stateId: try parsed.required("stateId", "--state"), ref: try parsed.required("ref", "--ref"), depth: parsed.integer("depth")))
	case .inspectUi:
		try parsed.noPositionals()
		return .inspectUi(InspectUiParams(stateId: try parsed.required("stateId", "--state"), ref: try parsed.required("ref", "--ref")))
	case .actUi:
		return .actUi(try actParams(parsed, stdin: stdin))
	case .readText:
		try parsed.noPositionals()
		return .readText(ReadTextParams(stateId: try parsed.required("stateId", "--state"), ref: try parsed.required("ref", "--ref"), offset: parsed.integer("offset"), limit: parsed.integer("limit")))
	case .waitFor:
		try parsed.noPositionals()
		_ = try parsed.required("stateId", "--state")
		if parsed.trimmed("text") == nil, parsed.trimmed("role") == nil { throw invalid("wait-for requires --text or --role.") }
		return .waitFor(WaitForParams(stateId: parsed.raw("stateId")!, text: parsed.raw("text"), role: parsed.raw("role"), scope: parsed.raw("scope"), gone: parsed.flag("gone"), timeoutMs: parsed.integer("timeoutMs")))
	}
}

private func actParams(_ parsed: ParsedOptions, stdin: () throws -> String) throws -> ActParams {
	if parsed.positionals != ["-"] { throw invalid("act-ui requires '-' and reads its JSON action array from stdin.") }
	let stateId = try parsed.required("stateId", "--state")
	let text = parsed.trimmed("expectText")
	let role = parsed.trimmed("expectRole")
	let value = parsed.trimmed("expectValue")
	let scope = parsed.trimmed("scope")
	let gone = parsed.flag("expectGone")
	let timeoutMs = parsed.integer("timeoutMs")
	let expects = text != nil || role != nil || value != nil
	if gone != nil || scope != nil || timeoutMs != nil, !expects {
		throw invalid("--expect-gone, --scope and --timeout require --expect-text, --expect-role, or --expect-value.")
	}
	return ActParams(
		stateId: stateId,
		actions: try validateActions(readActions(try stdin())),
		headless: parsed.flag("headless"),
		foreground: parsed.flag("foreground"),
		image: parsed.raw("image").flatMap(ImageMode.init(rawValue:)),
		expect: expects ? Expectation(text: text, role: role, value: value, scope: scope, gone: gone, timeoutMs: timeoutMs) : nil
	)
}

private func readActions(_ input: String) throws -> [JSONValue] {
	let parsed: JSONValue
	do {
		parsed = try JSONValue(parsing: input)
	} catch {
		throw invalid("act-ui stdin must be a JSON action array: \(error)")
	}
	guard case .array(let items) = parsed else { throw invalid("act-ui stdin must contain a JSON action array.") }
	for item in items where item["action"]?.string.flatMap(ActionName.init(rawValue:)) == nil {
		throw invalid("Every act-ui item must be an object with a supported action name.")
	}
	return items
}

private func optionHelp(_ options: [OptionSpec]) -> [String] {
	options.map { spec in
		let value = switch spec.kind {
		case .flag: ""
		case .string(let allowed?): " " + allowed.joined(separator: "|")
		case .string(nil): " <value>"
		case .integer: " <n>"
		}
		let label = spec.flag + value
		return "  " + Text.padEnd(label, helpColumn) + (Text.length(label) > helpColumn ? " " : "") + spec.doc
	}
}

private func commandHelp(_ name: CommandName) -> String {
	let spec = commandSpecs[name]!
	return ([
		"bcu \(name.rawValue)\(spec.arguments.map { " " + $0 } ?? "") [options]",
		"",
		spec.summary,
		"",
		"Options:",
	] + optionHelp(spec.options) + ["  " + Text.padEnd("--json", helpColumn) + "emit one JSON object on stdout"]).joined(separator: "\n")
}

private func overviewHelp() -> String {
	let commands = CommandName.allCases.map { "  " + Text.padEnd($0.rawValue, 16) + commandSpecs[$0]!.summary }
	let plain = PlainCommand.allCases.map { "  " + Text.padEnd($0.rawValue, 16) + $0.summary }
	return (["bcu <command> [options]", "", "Commands:"] + commands + plain + [
		"",
		"Every command takes --json for one JSON object on stdout, and --help for its own options.",
		"Failures write nothing to stdout and report 'error <code>' plus 'recovery' on stderr.",
	]).joined(separator: "\n")
}
