import AppKit
import BCUCore

extension Platform {
	/// Waits until an element matching role, text or value appears in the root (or, with
	/// `gone`, until none does), re-reading the tree whenever the app reports a change.
	public func waitFor(_ request: WaitForRequest) throws -> WaitOutcome {
		let pid = request.pid
		ensureEnhancedAccessibility(pid: pid)
		let role = request.role?.trimmingCharacters(in: .whitespacesAndNewlines)
		let text = request.text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		let expectedValue = request.value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		let timeoutMs = max(100, min(60_000, request.timeoutMs ?? 10_000))
		let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
		guard role?.isEmpty == false || text?.isEmpty == false || expectedValue?.isEmpty == false else {
			throw BCUError(.invalidArguments, "A wait needs a role, text, or value.")
		}
		guard let window = resolveRoot(pid: pid, windowId: nil, root: request.root) else {
			return .rootNotFound
		}
		let rootElement: AXUIElement
		if let scope = request.scope {
			guard let scoped = scope.elementRecord?.element.element, isElement(scoped, descendantOf: window) else {
				throw BCUError(.elementNotFound, "Condition scope ref is stale or outside the target root")
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

		repeat {
			let changeGeneration = rootChangeGeneration(pid: pid)
			let present = collectDescendants(startingAt: rootElement, maxDepth: 12, maxNodes: 2000).contains(where: matches)
			if present != request.gone { return request.gone ? .gone : .found }
			waitForRootChange(pid: pid, since: changeGeneration, until: deadline)
		} while Date() < deadline
		return .timedOut
	}

	/// A page of an element's text value, counted in characters. Secure fields are refused.
	public func readText(_ handle: Handle, offset: Int, limit: Int) throws -> TextPage {
		let offset = max(0, offset)
		let limit = max(1, min(100_000, limit))
		guard let element = handle.elementRecord?.element.element else {
			throw BCUError(.elementNotFound, "Element reference is no longer valid")
		}
		let role = stringAttribute(element, attribute: kAXRoleAttribute as CFString) ?? ""
		let subrole = stringAttribute(element, attribute: kAXSubroleAttribute as CFString) ?? ""
		guard !isSecureTextElement(role: role, subrole: subrole) else {
			throw BCUError(.actionFailed, "Refers to a secure text field; refusing to read its value")
		}
		guard let value = stringAttribute(element, attribute: kAXValueAttribute as CFString) else {
			throw BCUError(.actionFailed, "Element has no readable AXValue. Call snapshot/screenshot and choose a text-bearing ref.")
		}
		let characters = Array(value)
		if offset >= characters.count {
			return TextPage(text: "", offset: offset, limit: limit, totalChars: characters.count, hasMore: false)
		}
		let end = min(characters.count, offset + limit)
		return TextPage(text: String(characters[offset..<end]), offset: offset, limit: limit, totalChars: characters.count, hasMore: end < characters.count)
	}
}
