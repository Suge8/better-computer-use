import AppKit

// The helper wire protocol: each request line is `{id, cmd, ...args}` and is answered with
// `{id, ok: true, result}` or `{id, ok: false, error: {code, message}}`. This file maps it
// onto the Platform API; src/macos/protocol.ts is the Broker's side of the same shapes.

/// Bumped whenever a request or result below changes shape; the Broker refuses a helper
/// whose version differs.
let helperProtocolVersion = 10

extension HelperServer {
	func handleRequest(_ request: WireRequest) throws -> Any {
		let cmd = try request.string("cmd")
		switch cmd {
		case "diagnostics":
			return diagnosticsObject()
		case "checkPermissions":
			return platform.checkPermissions().wireObject()
		case "registerPermissions":
			let registration = platform.registerPermissions()
			return ["accessibility": registration.accessibility, "screenRecording": registration.screenRecording, "screenRecordingCapturable": registration.screenRecording]
		case "shutdown":
			// Reply first, then exit: the caller relaunches the helper to get a
			// process with a fresh TCC client (grant answers are cached per
			// process, so a helper that saw "denied" keeps answering "denied"
			// after the user grants — only a new process re-queries tccd).
			// Background queue: the serve loop occupies the main thread, so a
			// main-queue timer would never fire.
			DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { exit(0) }
			return ["shuttingDown": true]
		case "listApps":
			return platform.listApps().map { $0.wireObject() }
		case "listRoots":
			return ["roots": platform.listRoots(pid: request.optionalInt("pid").map { Int32($0) }, title: request.optionalString("title")).map { $0.wireObject() }]
		case "getFrontmost":
			return try platform.frontmost().wireObject()
		case "focusWindow":
			return platform.focusWindow(try request.rootTarget()).wireObject()
		case "look":
			return try platform.look(try request.lookRequest()).wireObject()
		case "act":
			return try platform.act(try request.actRequest()).wireObject()
		case "actBatch":
			guard let actions = request.fields["actions"] as? [[String: Any]], !actions.isEmpty, actions.count <= 20 else {
				throw PlatformError(message: "actBatch requires 1...20 actions", code: "invalid_args")
			}
			return try platform.actBatch(try actions.map { try WireRequest($0).actRequest() }).wireObject()
		case "hitTest":
			return try platform.hitTest(lookId: try request.string("lookId"), x: try request.double("x"), y: try request.double("y")).wireObject()
		case "axWaitFor":
			return try platform.waitFor(try request.waitForRequest()).wireObject()
		case "axReadText":
			return try platform.readText(ReadTextRequest(elementRef: try request.string("elementRef"), offset: request.optionalInt("offset") ?? 0, limit: request.optionalInt("limit") ?? 4_000)).wireObject()
		default:
			throw PlatformError(message: "Unknown command '\(cmd)'", code: "unknown_command")
		}
	}

	private func diagnosticsObject() -> [String: Any] {
		let diagnostics = platform.diagnostics()
		var output: [String: Any] = [
			"protocolVersion": helperProtocolVersion,
			"architectureVersion": 1,
			"invariants": ["state-scoped-observations", "bounded-observation-history", "multi-root-forest", "progressive-disclosure", "atomic-physical-input", "concurrent-requests", "transactional-batching"],
			"pid": diagnostics.pid,
			"parentPid": diagnostics.parentPid,
			"executablePath": diagnostics.executablePath,
			"macOS": diagnostics.macOS,
			"arch": diagnostics.arch,
			"accessibility": diagnostics.accessibility,
			"screenRecording": diagnostics.screenRecording,
			"recentCompletedRequestIds": completedRequestIds(),
		]
		output["parentPath"] = diagnostics.parentPath
		output["parentAppName"] = diagnostics.parentAppName
		output["parentBundleId"] = diagnostics.parentBundleId
		return output
	}
}

// MARK: Requests

/// One decoded request line and typed access to its arguments.
struct WireRequest {
	let fields: [String: Any]

	init(_ fields: [String: Any]) {
		self.fields = fields
	}

	func string(_ key: String) throws -> String {
		guard let value = fields[key] as? String else {
			throw PlatformError(message: "Missing string argument '\(key)'", code: "invalid_args")
		}
		return value
	}

	func optionalString(_ key: String) -> String? {
		fields[key] as? String
	}

	func int(_ key: String) throws -> Int {
		guard let value = optionalInt(key) else {
			throw PlatformError(message: "Missing integer argument '\(key)'", code: "invalid_args")
		}
		return value
	}

	func optionalInt(_ key: String) -> Int? {
		if let value = fields[key] as? Int { return value }
		if let value = fields[key] as? NSNumber { return value.intValue }
		if let value = fields[key] as? Double { return Int(value) }
		return nil
	}

	func optionalBool(_ key: String) -> Bool? {
		if let value = fields[key] as? Bool { return value }
		if let value = fields[key] as? NSNumber { return value.boolValue }
		return nil
	}

	func double(_ key: String) throws -> Double {
		if let value = fields[key] as? Double { return value }
		if let value = fields[key] as? NSNumber { return value.doubleValue }
		if let value = fields[key] as? Int { return Double(value) }
		throw PlatformError(message: "Missing numeric argument '\(key)'", code: "invalid_args")
	}

	func rootTarget() throws -> RootTarget {
		RootTarget(pid: Int32(try int("pid")), windowId: optionalInt("windowId").map { UInt32($0) }, rootRef: optionalString("rootRef"))
	}

	func lookRequest() throws -> LookRequest {
		let windowId = optionalInt("windowId").map { UInt32($0) }
		let rootRef = try string("rootRef")
		let maxDimension = optionalInt("maxDimension")
		guard let readText = ReadTextMode(rawValue: optionalString("readText") ?? "auto") else {
			throw PlatformError(message: "readText must be auto, always, or never", code: "invalid_args")
		}
		return LookRequest(rootRef: rootRef, windowId: windowId, maxDimension: maxDimension, readText: readText, baseLookId: optionalString("baseLookId"), includeImage: optionalBool("includeImage") ?? true, scopeRef: optionalString("scopeRef"))
	}

	func actRequest() throws -> ActRequest {
		let lookId = try string("lookId")
		let pid = Int32(try int("pid"))
		let actionName = try string("action")
		guard let action = ActAction(rawValue: actionName) else {
			throw PlatformError(message: "Action \(actionName) cannot use coordinate grounding", code: "invalid_args")
		}
		let target = fields["target"] as? [String: Any] ?? [:]
		let actTarget: ActTarget
		if let ref = target["ref"] as? String {
			actTarget = .ref(ref)
		} else if let x = target["x"] as? NSNumber, let y = target["y"] as? NSNumber {
			actTarget = .point(x: x.doubleValue, y: y.doubleValue)
		} else {
			throw PlatformError(message: "act target must include ref or x/y", code: "invalid_args")
		}
		let params = fields["params"] as? [String: Any] ?? [:]
		let path = try (params["path"] as? [[String: Any]]).map { entries in
			try entries.map { entry -> CGPoint in
				guard let x = (entry["x"] as? NSNumber)?.doubleValue, let y = (entry["y"] as? NSNumber)?.doubleValue else {
					throw PlatformError(message: "drag path entries require x and y", code: "invalid_args")
				}
				return CGPoint(x: x, y: y)
			}
		}
		return ActRequest(
			lookId: lookId,
			pid: pid,
			action: action,
			target: actTarget,
			params: ActParams(
				button: Self.mouseButton(params["button"] as? String ?? "left"),
				clickCount: (params["clickCount"] as? NSNumber)?.intValue ?? 1,
				scrollX: (params["scrollX"] as? NSNumber)?.intValue ?? 0,
				scrollY: (params["scrollY"] as? NSNumber)?.intValue ?? 0,
				path: path,
				text: params["text"] as? String ?? "",
				keys: params["keys"] as? [String] ?? [],
				preserveFocus: params["preserveFocus"] as? Bool ?? false,
				pidDelivery: (params["delivery"] as? String) == "pid"
			),
			policy: ActPolicy(rawValue: optionalString("policy") ?? "") ?? .default,
			cursorOverlay: fields["cursorOverlay"] as? Bool ?? true
		)
	}

	private static func mouseButton(_ name: String) -> CGMouseButton {
		switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
		case "right":
			return .right
		case "middle", "center":
			return .center
		default:
			return .left
		}
	}

	func waitForRequest() throws -> WaitForRequest {
		WaitForRequest(
			target: try rootTarget(),
			role: optionalString("role"),
			text: optionalString("text"),
			value: optionalString("value"),
			gone: optionalBool("gone") ?? false,
			scopeRef: optionalString("scopeRef"),
			scopeExact: optionalBool("scopeExact") ?? false,
			timeoutMs: optionalInt("timeoutMs")
		)
	}
}

// MARK: Results

private func frameObject(_ rect: CGRect) -> [String: Any] {
	["x": rect.origin.x, "y": rect.origin.y, "w": rect.width, "h": rect.height]
}

extension PermissionStatus {
	func wireObject() -> [String: Any] {
		var source: [String: Any] = [
			"pid": Int(self.source.pid),
			"parentPid": Int(self.source.parentPid),
			"executablePath": self.source.executablePath,
			"macOS": self.source.macOS,
			"attribution": self.source.attribution.rawValue,
		]
		source["parentPath"] = self.source.parentPath
		source["parentBundleId"] = self.source.parentBundleId
		return [
			"accessibility": accessibility,
			"screenRecording": screenRecording,
			"screenRecordingPreflight": screenRecordingPreflight,
			"screenRecordingCapturable": screenRecording,
			"source": source,
		]
	}
}

extension RunningApp {
	func wireObject() -> [String: Any] {
		var output: [String: Any] = ["appName": appName, "pid": Int(pid), "isFrontmost": isFrontmost]
		output["bundleId"] = bundleId
		return output
	}
}

extension RootMetadata {
	func wireObject() -> [String: Any] {
		["pairing": ["confidence": pairing.confidence.rawValue, "score": pairing.score], "sheetCount": sheetCount]
	}
}

extension Root {
	func wireObject() -> [String: Any] {
		var output: [String: Any] = [
			"kind": kind.rawValue,
			"rootRef": rootRef,
			"zOrder": zOrder,
			"title": title,
			"role": role,
			"subrole": subrole,
			"isModal": isModal,
			"framePoints": frameObject(framePoints),
			"scaleFactor": scaleFactor,
			"isMinimized": isMinimized,
			"isOnscreen": isOnscreen,
			"isMain": isMain,
			"isFocused": isFocused,
			"pid": Int(pid),
			"appName": appName,
		]
		output["windowId"] = windowId.map { Int($0) }
		output["metadata"] = metadata?.wireObject()
		output["bundleId"] = bundleId
		return output
	}
}

extension Frontmost {
	func wireObject() -> [String: Any] {
		var output: [String: Any] = ["appName": appName, "pid": Int(pid)]
		output["bundleId"] = bundleId
		if let window {
			output["windowTitle"] = window.title
			output["windowId"] = window.windowId.map { Int($0) }
			output["rootRef"] = window.rootRef
		}
		return output
	}
}

extension FocusWindowResult {
	func wireObject() -> [String: Any] {
		var output: [String: Any] = ["focused": focused]
		if alreadyFocused { output["alreadyFocused"] = true }
		output["setMain"] = setMain
		output["setFocused"] = setFocused
		output["raised"] = raised
		output["reason"] = reason
		return output
	}
}

extension LookNode {
	func wireObject() -> [String: Any] {
		var output: [String: Any] = [
			"ref": ref,
			"role": role,
			"subrole": subrole,
			"identifier": identifier,
			"title": title,
			"description": description,
			"value": value,
			"actions": actions,
			"canPress": canPress,
			"canFocus": canFocus,
			"canSetValue": canSetValue,
			"canScroll": canScroll,
			"canIncrement": canIncrement,
			"canDecrement": canDecrement,
			"isTextInput": isTextInput,
			"rect": frameObject(rect),
			"children": children.map { $0.wireObject() },
		]
		if focused { output["focused"] = true }
		if offscreen { output["offscreen"] = true }
		if pictureOnly { output["pictureOnly"] = true }
		if truncated { output["truncated"] = true }
		if let scrollExtent { output["scrollExtent"] = ["seen": scrollExtent.seen, "total": scrollExtent.total] }
		return output
	}
}

extension LookResult {
	func wireObject() -> [String: Any] {
		var output: [String: Any] = [
			"lookId": lookId,
			"capturedAt": capturedAt.timeIntervalSince1970,
			"window": [
				"windowId": Int(window.windowId),
				"rootRef": window.rootRef,
				"kind": window.kind.rawValue,
				"framePoints": frameObject(window.framePoints),
				"scaleFactor": window.scaleFactor,
				"isModal": window.isModal,
				"metadata": window.metadata.wireObject(),
				"role": window.role,
				"subrole": window.subrole,
			],
			"outline": outline.wireObject(),
			"timings": ["captureMs": timings.captureMs, "describeMs": timings.describeMs, "readTextMs": timings.readTextMs],
		]
		if let readText { output["readText"] = ["requested": readText.requested.rawValue, "executed": readText.executed] }
		if let image { output["image"] = ["jpegBase64": image.jpeg.base64EncodedString(), "width": image.width, "height": image.height] }
		return output
	}
}

extension ActPerformed {
	func wireObject() -> [String: Any] {
		var output: [String: Any] = ["delivery": delivery.rawValue]
		output["grounding"] = grounding?.rawValue
		if refound { output["refound"] = true }
		if focusedWindow { output["focusedWindow"] = true }
		if backgroundActivation { output["backgroundActivation"] = true }
		output["activated"] = activated
		output["raised"] = raised
		if focused { output["focused"] = true }
		if selectedAllViaAX { output["selectionGrounding"] = "ax" }
		if openedMenus { output["openedMenus"] = true }
		if callerMustVerify { output["verification"] = "caller_required" }
		output["deltaSource"] = deltaSource?.rawValue
		return output
	}
}

extension ActEvidence {
	func wireObject() -> [String: Any] {
		var output: [String: Any] = ["source": source.rawValue]
		output["field"] = field
		output["from"] = from
		output["to"] = to
		return output
	}
}

extension RootChange {
	func wireObject() -> [String: Any] {
		switch self {
		case .root(let change, let root):
			var output = root.wireObject()
			output["change"] = change.rawValue
			return output
		case .frontApp(let title, let pid):
			return ["change": RootChangeKind.focused.rawValue, "kind": "app", "title": title, "pid": Int(pid)]
		}
	}
}

extension ActResult {
	func wireObject() -> [String: Any] {
		var output: [String: Any] = ["outcome": outcome.rawValue, "performed": performed.wireObject()]
		output["verification"] = verification?.wireObject()
		if !rootDelta.isEmpty { output["rootDelta"] = rootDelta.map { $0.wireObject() } }
		return output
	}
}

extension ActBatchResult {
	func wireObject() -> [String: Any] {
		var output: [String: Any] = [
			"outcome": outcome.rawValue,
			"performed": ["transaction": true, "actionCount": steps.count, "deltaSource": deltaSource.rawValue],
			"steps": steps.map { step -> [String: Any] in
				switch step {
				case .completed(let result):
					return result.wireObject()
				case .failed(let failure):
					return ["outcome": ActOutcome.didnt.rawValue, "error": ["code": failure.code, "message": failure.message]]
				}
			},
		]
		output["stoppedAt"] = stoppedAt
		output["verification"] = verification?.wireObject()
		if !rootDelta.isEmpty { output["rootDelta"] = rootDelta.map { $0.wireObject() } }
		return output
	}
}

extension WaitForResult {
	func wireObject() -> [String: Any] {
		switch self {
		case .found(let match, let nodeCount):
			return ["found": true, "target": match.wireObject(), "nodeCount": nodeCount]
		case .gone(let nodeCount):
			return ["found": true, "gone": true, "nodeCount": nodeCount]
		case .timedOut(let nodeCount):
			return ["found": false, "timedOut": true, "nodeCount": nodeCount]
		case .rootNotFound:
			return ["found": false, "reason": "window_not_found"]
		}
	}
}

extension ElementMatch {
	func wireObject() -> [String: Any] {
		var output: [String: Any] = [
			"target": true,
			"elementRef": elementRef,
			"role": role,
			"subrole": subrole,
			"title": title,
			"description": description,
			"identifier": identifier,
			"value": value,
			"actions": actions,
			"isTextInput": isTextInput,
			"canSetValue": canSetValue,
			"canFocus": canFocus,
			"canPress": canPress,
			"canScroll": canScroll,
			"canIncrement": canIncrement,
			"canDecrement": canDecrement,
			"axVisible": true,
			"x": frame.map { $0.midX } ?? 0,
			"y": frame.map { $0.midY } ?? 0,
			"source": source.rawValue,
		]
		output["frame"] = frame.map(frameObject)
		output["parentFrame"] = parentFrame.map(frameObject)
		return output
	}
}

extension ReadTextResult {
	func wireObject() -> [String: Any] {
		["text": text, "offset": offset, "limit": limit, "totalChars": totalChars, "hasMore": hasMore]
	}
}
