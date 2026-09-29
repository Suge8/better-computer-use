import AppKit

extension Platform {
	/// Waits until an element matching role, text or value appears in the root (or, with
	/// `gone`, until none does), re-reading the tree whenever the app reports a change.
	public func waitFor(_ request: WaitForRequest) throws -> WaitForResult {
		let pid = request.target.pid
		ensureEnhancedAccessibility(pid: pid)
		let role = request.role?.trimmingCharacters(in: .whitespacesAndNewlines)
		let text = request.text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		let expectedValue = request.value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		let timeoutMs = max(100, min(60_000, request.timeoutMs ?? 10_000))
		let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
		guard role?.isEmpty == false || text?.isEmpty == false || expectedValue?.isEmpty == false else {
			throw PlatformError(message: "axWaitFor requires role, text, or value", code: "invalid_args")
		}
		guard let window = resolveRoot(pid: pid, windowId: request.target.windowId, rootRef: request.target.rootRef) else {
			return .rootNotFound
		}
		let rootElement: AXUIElement
		if let scopeRef = request.scopeRef {
			guard let scoped = refStore.element(for: scopeRef), isElement(scoped, descendantOf: window) else {
				throw PlatformError(message: "Condition scope ref is stale or outside the target root", code: "element_ref_invalid")
			}
			rootElement = scoped
		} else {
			rootElement = window
		}
		_ = ensureRootObserver(pid: pid)

		func matches(_ element: AXUIElement) -> Bool {
			let candidateRole = stringAttribute(element, attribute: kAXRoleAttribute as CFString) ?? ""
			if let role, !role.isEmpty, candidateRole != role { return false }
			if let text, !text.isEmpty {
				let subrole = stringAttribute(element, attribute: kAXSubroleAttribute as CFString) ?? ""
				let haystack = [
					stringAttribute(element, attribute: kAXTitleAttribute as CFString) ?? "",
					stringAttribute(element, attribute: kAXDescriptionAttribute as CFString) ?? "",
					displayValue(element, role: candidateRole, subrole: subrole),
				].joined(separator: "\n").lowercased()
				if !haystack.contains(text) { return false }
			}
			if let expectedValue, !expectedValue.isEmpty {
				let subrole = stringAttribute(element, attribute: kAXSubroleAttribute as CFString) ?? ""
				if displayValue(element, role: candidateRole, subrole: subrole).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != expectedValue { return false }
			}
			return true
		}

		var lastCount = 0
		repeat {
			let changeGeneration = rootChangeGeneration(pid: pid)
			let collected = collectDescendantsWithContext(startingAt: rootElement, maxDepth: 12, maxNodes: 2000)
			let descendants = request.scopeExact ? Array(collected.prefix(1)) : collected
			lastCount = descendants.count
			if let match = descendants.first(where: { matches($0.element) }) {
				if request.gone {
					waitForRootChange(pid: pid, since: changeGeneration, until: deadline)
					continue
				}
				let candidateRole = stringAttribute(match.element, attribute: kAXRoleAttribute as CFString) ?? ""
				let containsWebArea = descendants.contains { stringAttribute($0.element, attribute: kAXRoleAttribute as CFString) == "AXWebArea" }
				let source = axSource(role: candidateRole, insideWebArea: match.insideWebArea, isBrowser: isBrowser(pid: pid), containsWebArea: containsWebArea)
				return .found(elementMatch(match.element, source: source), nodeCount: lastCount)
			}
			if request.gone {
				return .gone(nodeCount: lastCount)
			}
			waitForRootChange(pid: pid, since: changeGeneration, until: deadline)
		} while Date() < deadline

		return .timedOut(nodeCount: lastCount)
	}

	func elementMatch(_ element: AXUIElement, source: ElementSource) -> ElementMatch {
		let role = stringAttribute(element, attribute: kAXRoleAttribute as CFString) ?? ""
		let subrole = stringAttribute(element, attribute: kAXSubroleAttribute as CFString) ?? ""
		var valueSettable = DarwinBoolean(false)
		let valueStatus = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable)
		var focusedSettable = DarwinBoolean(false)
		let focusedStatus = AXUIElementIsAttributeSettable(element, kAXFocusedAttribute as CFString, &focusedSettable)
		let actions = actionNames(element)
		let textRoles: Set<String> = [
			"AXTextField", "AXTextArea", "AXTextView", "AXSearchField", "AXComboBox", "AXEditableText", "AXSecureTextField",
		]
		return ElementMatch(
			elementRef: refStore.storeElement(element),
			role: role,
			subrole: subrole,
			title: stringAttribute(element, attribute: kAXTitleAttribute as CFString) ?? "",
			description: stringAttribute(element, attribute: kAXDescriptionAttribute as CFString) ?? "",
			identifier: stringAttribute(element, attribute: "AXIdentifier" as CFString) ?? "",
			value: displayValue(element, role: role, subrole: subrole),
			actions: actions,
			isTextInput: textRoles.contains(role),
			canSetValue: valueStatus == .success && valueSettable.boolValue,
			canFocus: focusedStatus == .success && focusedSettable.boolValue,
			canPress: actions.contains(kAXPressAction as String),
			canScroll: supportsAnyScrollAction(element),
			canIncrement: actions.contains(kAXIncrementAction as String),
			canDecrement: actions.contains(kAXDecrementAction as String),
			frame: frameForElement(element),
			parentFrame: copyAttribute(element, attribute: kAXParentAttribute as CFString).flatMap(asAXElement).flatMap(frameForElement),
			source: source
		)
	}

	/// A page of an element's text value, counted in characters. Secure fields are refused.
	public func readText(_ request: ReadTextRequest) throws -> ReadTextResult {
		let offset = max(0, request.offset)
		let limit = max(1, min(100_000, request.limit))
		guard let element = refStore.element(for: request.elementRef) else {
			throw PlatformError(message: "Element reference is no longer valid", code: "element_ref_invalid")
		}
		let role = stringAttribute(element, attribute: kAXRoleAttribute as CFString) ?? ""
		let subrole = stringAttribute(element, attribute: kAXSubroleAttribute as CFString) ?? ""
		guard !isSecureTextElement(role: role, subrole: subrole) else {
			throw PlatformError(message: "Refers to a secure text field; refusing to read its value", code: "secure_text_unreadable")
		}
		guard let value = stringAttribute(element, attribute: kAXValueAttribute as CFString) else {
			throw PlatformError(message: "Element has no readable AXValue. Call snapshot/screenshot and choose a text-bearing ref.", code: "text_unavailable")
		}
		let characters = Array(value)
		if offset >= characters.count {
			return ReadTextResult(text: "", offset: offset, limit: limit, totalChars: characters.count, hasMore: false)
		}
		let end = min(characters.count, offset + limit)
		return ReadTextResult(text: String(characters[offset..<end]), offset: offset, limit: limit, totalChars: characters.count, hasMore: end < characters.count)
	}
}
