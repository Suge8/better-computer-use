// The Swift core must reproduce the TS implementation byte for byte. Golden/ holds the outputs
// scripts/generate-swift-golden.mjs recorded from the TS code on the same inputs; each case
// names the operation, its input and every output stream it produced.
import BCUCore
import Foundation
import Testing

private let testsDirectory = URL(filePath: #filePath).deletingLastPathComponent()
private let fixturesDirectory = testsDirectory.appending(path: "../../scripts/fixtures").standardizedFileURL

struct GoldenCase: Sendable, CustomTestStringConvertible {
	let file: String
	let name: String
	let op: String
	let input: JSONValue
	let output: JSONValue
	let compare: String?

	var testDescription: String { "\(file): \(name)" }

	static func load(_ file: String) -> [GoldenCase] {
		let url = testsDirectory.appending(path: "Golden/\(file).json")
		guard let text = try? String(contentsOf: url, encoding: .utf8), let root = try? JSONValue(parsing: text), let cases = root["cases"]?.array else {
			fatalError("unreadable golden file \(url.path)")
		}
		return cases.map { item in
			GoldenCase(
				file: file,
				name: item["name"]?.string ?? "",
				op: item["op"]?.string ?? "",
				input: item["input"] ?? .object([]),
				output: item["output"] ?? .object([]),
				compare: item["compare"]?.string
			)
		}
	}
}

// MARK: - inputs

private func loadOutline(_ input: JSONValue) throws -> Outline {
	let source: JSONValue
	if let fixture = input["fixture"]?.string {
		source = try JSONValue(parsing: String(contentsOf: fixturesDirectory.appending(path: fixture), encoding: .utf8))
	} else {
		source = input["outline"] ?? .null
	}
	let serialized = try JSONCoding.decode(SerializedOutline.self, from: source)
	if input["numbering"]?.string == "saved" { return Outline(restoring: serialized) }
	return Outline(root: OutlineNode(serialized.root))
}

private func json<T: Encodable>(_ value: T) throws -> JSONValue {
	try JSONCoding.encode(value)
}

private func refs(_ value: JSONValue?) -> Set<String>? {
	value?.array.map { Set($0.compactMap(\.string)) }
}

private func image(_ value: JSONValue?) -> ImageSize? {
	guard let width = value?["width"]?.number, let height = value?["height"]?.number else { return nil }
	return ImageSize(width: Int(width), height: Int(height))
}

/** Errors print as the CLI prints them; stdin parse failures keep only the stable prefix. */
private let stdinPrefix = "act-ui stdin must be a JSON action array: "

private func withoutParserDetail(_ stderr: String) -> String {
	guard let range = stderr.range(of: stdinPrefix) else { return stderr }
	let lineEnd = stderr[range.upperBound...].firstIndex(of: "\n") ?? stderr.endIndex
	return stderr.replacingCharacters(in: range.upperBound..<lineEnd, with: "<parser detail>")
}

private func failure(_ error: any Error) -> [String: JSONValue] {
	let normalized = BCUError.normalize(error)
	return ["stdout": .string(""), "stderr": .string(withoutParserDetail(normalized.formatted)), "exitCode": .number(Double(normalized.exitCode))]
}

private func streams(stdout: String) -> [String: JSONValue] {
	["stdout": .string(stdout), "stderr": .string(""), "exitCode": .number(0)]
}

// MARK: - operations

private func run(_ golden: GoldenCase) -> [String: JSONValue] {
	do {
		return try perform(golden.op, golden.input)
	} catch {
		return failure(error)
	}
}

private func perform(_ op: String, _ input: JSONValue) throws -> [String: JSONValue] {
	switch op {
	case "build":
		return ["json": .string(try JSONCoding.string(loadOutline(input["outline"]!).serialized))]
	case "stabilize":
		let next = try loadOutline(input["next"]!)
		next.stabilizeRefs(against: try loadOutline(input["base"]!))
		return ["json": .string(try JSONCoding.string(next.serialized))]
	case "graft":
		let outline = try loadOutline(input["outline"]!)
		let grafted = try outline.graft(try loadOutline(input["scoped"]!), at: input["target"]!.string!)
		let value = JSONValue.object([JSONMember("ref", .string(grafted.ref)), JSONMember("outline", try json(outline.serialized))])
		return ["json": .string(value.serialized())]
	case "project":
		return try projectCase(input)
	case "changes":
		return try changesCase(input)
	case "successor":
		let base = try loadOutline(input["base"]!)
		let next = try loadOutline(input["next"]!)
		next.stabilizeRefs(against: base)
		let view = successorView(base: base, next: next, menusOpenedByBcu: input["menusOpenedByBcu"]?.bool ?? false)
		return ["json": .string(try JSONCoding.string(view))]
	case "validate":
		let actions = try validateActions(input["actions"]!.array!)
		return ["ok": .string(try json(actions).serialized(sortedKeys: true))]
	case "prepare":
		let action = try JSONCoding.decode(UiAction.self, from: input["action"]!)
		let environment = ActionEnvironment(outline: try loadOutline(input["outline"]!), image: image(input["image"]), headless: input["headless"]!.bool!)
		let prepared = try prepareAction(action, state: ActionState(currentFocus: input["currentFocus"]!.bool!), environment: environment)
		return ["prepared": .string(try json(prepared).serialized(sortedKeys: true))]
	case "deliver":
		let actions = try validateActions([input["action"]!])
		let environment = ActionEnvironment(outline: try loadOutline(input["outline"]!), image: image(input["image"]), headless: false)
		let prepared = try json(prepareAction(actions[0], state: ActionState(currentFocus: false), environment: environment))
		let request = JSONValue.object(["action", "target", "params"].map { JSONMember($0, prepared[$0]!) })
		return ["request": .string(request.serialized(sortedKeys: true))]
	case "outcome":
		return ["result": .string(try outcomeCase(input))]
	case "observedValues":
		let actions = try input["actions"]!.array!.map { try JSONCoding.decode(UiAction.self, from: $0) }
		let values = input["values"]!
		let outcome = outcomeAfterObservedValues(ActOutcome(rawValue: input["current"]!.string!)!, actions: actions) { values[$0]?.string }
		return ["result": .string(JSONValue.string(outcome.rawValue).serialized())]
	case "error":
		let error = BCUError(ErrorCode(rawValue: input["code"]!.string!)!, input["message"]!.string!, recovery: input["recovery"]?.string)
		return ["stderr": .string(error.formatted), "exitCode": .number(Double(error.exitCode))]
	case "cli":
		return try cliCase(input)
	case "query":
		return try queryCase(input)
	default:
		Issue.record("unknown golden operation \(op)")
		return [:]
	}
}

private func projectCase(_ input: JSONValue) throws -> [String: JSONValue] {
	let outline = try loadOutline(input["outline"]!)
	let options = input["options"] ?? .object([])
	var projectOptions = ProjectOptions()
	projectOptions.maxDepth = options["maxDepth"]?.number.map { Int($0) }
	projectOptions.maxNodes = options["maxNodes"]?.number.map { Int($0) }
	projectOptions.unfold = options["unfold"]?.array?.compactMap(\.string) ?? []
	projectOptions.from = options["from"]?.string.flatMap { outline.node($0) }
	let projection = project(outline, projectOptions)
	let value = JSONValue.object([
		JSONMember("nodes", try json(projection.nodes)),
		JSONMember("shown", .number(Double(projection.shown))),
		JSONMember("total", .number(Double(projection.total))),
		JSONMember("truncated", .bool(projection.truncated)),
	])
	let text: String
	if let header = input["header"] {
		let view = ObservationView(
			stateId: header["stateId"]!.string!,
			root: ObservationRoot(ref: header["root"]?["ref"]?.string, app: header["root"]!["app"]!.string!, title: header["root"]!["title"]!.string!),
			nodes: projection.nodes,
			shown: projection.shown,
			total: projection.total
		)
		text = renderObservation(view)
	} else {
		text = renderNodes(projection.nodes)
	}
	return ["json": .string(value.serialized()), "text": .string(text)]
}

private func changesCase(_ input: JSONValue) throws -> [String: JSONValue] {
	let base = try loadOutline(input["base"]!)
	let next = try loadOutline(input["next"]!)
	if input["stabilize"]?.bool == true { next.stabilizeRefs(against: base) }
	let transition = changesBetween(
		project(base, .unfolded).nodes,
		project(next, .unfolded).nodes,
		visible: refs(input["visible"]),
		baseVisible: refs(input["baseVisible"]),
		menusOpenedByBcu: input["menusOpenedByBcu"]?.bool ?? false
	)
	return [
		"json": .string(try JSONCoding.string(transition)),
		"text": .string(renderChanges(transition.changes)),
		"offscreen": .string(renderOffscreen(transition.offscreen)),
	]
}

private func outcomeCase(_ input: JSONValue) throws -> String {
	let args = input["args"]!.array!
	let current = ActOutcome(rawValue: args[0].string!)!
	switch input["fn"]!.string! {
	case "canRetryInForeground":
		return JSONValue.bool(canRetryInForeground(current, headless: args[1].bool!)).serialized()
	default:
		return JSONValue.string(outcomeAfterCheck(current, CheckResult(rawValue: args[1].string!)!).rawValue).serialized()
	}
}

private func parse(_ input: JSONValue) throws -> Invocation {
	let argv = input["argv"]!.array!.map { $0.string! }
	let stdin = input["stdin"]?.string ?? ""
	return try CLI.parse(argv, stdin: { stdin })
}

private func cliCase(_ input: JSONValue) throws -> [String: JSONValue] {
	switch try parse(input) {
	case .help(let text):
		return streams(stdout: text)
	case .plain(let command, _):
		Issue.record("plain command \(command.rawValue) has no golden result")
		return [:]
	case .command(let request, let asJSON):
		var output: [String: JSONValue] = [:]
		let encoded = try json(request)
		let sent = JSONValue.object([JSONMember("command", encoded["command"]!), JSONMember("json", .bool(asJSON)), JSONMember("params", encoded["params"]!)])
		output["request"] = .string(sent.serialized(sortedKeys: true))
		if let result = input["result"] {
			let decoded = try CommandResult.decode(request.name, from: result)
			output.merge(streams(stdout: try CLI.output(decoded, json: asJSON))) { $1 }
		}
		return output
	}
}

private func queryCase(_ input: JSONValue) throws -> [String: JSONValue] {
	guard case .command(let request, let asJSON) = try parse(input) else {
		Issue.record("query case did not parse to a command")
		return [:]
	}
	let outline = try loadOutline(input["outline"]!)
	let stateId = input["stateId"]!.string!
	let result: CommandResult
	switch request {
	case .observeUi:
		result = .observeUi(observeResult(stateId: stateId, root: try JSONCoding.decode(RootSummary.self, from: input["root"]!), outline: outline))
	case .searchUi(let params):
		result = .searchUi(try searchUI(params, in: outline, stateId: stateId))
	case .expandUi(let params):
		result = .expandUi(try expandUI(params, in: outline, stateId: stateId) { node in
			Issue.record("expand-ui asked for a scoped look of \(node.ref)")
			return outline
		})
	case .inspectUi(let params):
		result = .inspectUi(try inspectUI(params, in: outline, stateId: stateId))
	default:
		Issue.record("query case \(request.name.rawValue) is not a cached query")
		return [:]
	}
	return streams(stdout: try CLI.output(result, json: asJSON))
}

// MARK: - comparison

/** Only the key-sorted form is compared for cases whose TS key order is not the declared one. */
private func canonicalized(_ text: String) -> String {
	text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
		(try? JSONValue(parsing: String(line)))?.serialized(sortedKeys: true) ?? String(line)
	}.joined(separator: "\n")
}

private func check(_ golden: GoldenCase) {
	let actual = run(golden)
	guard case .object(let expected) = golden.output else { return }
	for member in expected {
		var want = member.value
		var got = actual[member.key] ?? .null
		if golden.compare == "canonical-json", member.key == "stdout", let wantText = want.string, let gotText = got.string {
			want = .string(canonicalized(wantText))
			got = .string(canonicalized(gotText))
		}
		if let wantText = want.string, let gotText = got.string {
			#expect(gotText == wantText, "\(member.key) differs")
		} else {
			#expect(got == want, "\(member.key) differs")
		}
	}
}

@Test(arguments: GoldenCase.load("outline")) func outline(_ golden: GoldenCase) { check(golden) }
@Test(arguments: GoldenCase.load("projection")) func projection(_ golden: GoldenCase) { check(golden) }
@Test(arguments: GoldenCase.load("view")) func view(_ golden: GoldenCase) { check(golden) }
@Test(arguments: GoldenCase.load("actions")) func actions(_ golden: GoldenCase) { check(golden) }
@Test(arguments: GoldenCase.load("errors")) func errors(_ golden: GoldenCase) { check(golden) }
@Test(arguments: GoldenCase.load("cli")) func cli(_ golden: GoldenCase) { check(golden) }
@Test(arguments: GoldenCase.load("queries")) func queries(_ golden: GoldenCase) { check(golden) }
