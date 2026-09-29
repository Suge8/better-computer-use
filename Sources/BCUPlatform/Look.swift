import AppKit

struct LookRecord {
	let lookId: String
	let windowId: UInt32
	let windowFrame: CGRect
	let imageWidth: Int
	let imageHeight: Int
	let hasImage: Bool
}

extension Bridge {
	/// A popup menu Accessibility never exposed still has screen geometry, so callers get a
	/// picture-only root rather than a failure they cannot act on.
	func cgMenuLook(rootRef: String, windowId: UInt32, capturedAt: Date) -> [String: Any] {
		let frame = windowInfo(windowId: windowId)?.bounds ?? CGRect(x: 0, y: 0, width: 1, height: 1)
		let lookId = freshLookId()
		storeLookRecord(LookRecord(lookId: lookId, windowId: windowId, windowFrame: frame, imageWidth: max(1, Int(frame.width)), imageHeight: max(1, Int(frame.height)), hasImage: false))
		let outline = LookNode(element: nil, ref: rootRef, role: "AXMenu", subrole: "", identifier: "", title: "Menu", description: "", value: "", actions: [], canPress: false, canFocus: false, canSetValue: false, canScroll: false, canIncrement: false, canDecrement: false, isTextInput: false, rect: CGRect(x: 0, y: 0, width: max(1, frame.width), height: max(1, frame.height)), pictureOnly: true)
		return [
			"lookId": lookId,
			"capturedAt": capturedAt.timeIntervalSince1970,
			"window": ["windowId": Int(windowId), "rootRef": rootRef, "kind": "menu", "framePoints": ["x": frame.origin.x, "y": frame.origin.y, "w": frame.width, "h": frame.height], "scaleFactor": displayScaleFactor(for: frame), "isModal": false, "metadata": ["pairing": ["confidence": "low", "score": 0], "sheetCount": 0], "role": "AXMenu", "subrole": ""],
			"outline": outline.payload(),
			"timings": ["captureMs": 0, "describeMs": 0, "readTextMs": 0],
		]
	}

	func look(_ request: [String: Any]) throws -> [String: Any] {
		let windowId = optionalIntArg(request, "windowId").map { UInt32($0) }
		let rootRef = try stringArg(request, "rootRef")
		let maxDimension = optionalIntArg(request, "maxDimension").map { max(1, $0) }
		let readText = optionalStringArg(request, "readText") ?? "auto"
		let baseLookId = optionalStringArg(request, "baseLookId")
		let includeImage = boolArg(request, "includeImage") ?? true
		guard readText == "auto" || readText == "always" || readText == "never" else {
			throw BridgeFailure(message: "readText must be auto, always, or never", code: "invalid_args")
		}

		let requestedRoot = refStore.window(for: rootRef)
		let requestedRole = requestedRoot.flatMap { stringAttribute($0, attribute: kAXRoleAttribute as CFString) } ?? ""
		let isMenuRoot = requestedRole == "AXMenu" || rootRef.hasPrefix(cgMenuRefPrefix)
		let captureStart = Date()
		var captureMs = 0
		func capturedWindow() throws -> CapturedWindowImage? {
			guard !isMenuRoot, let windowId else { return nil }
			let started = Date()
			defer { captureMs = elapsedMs(started) }
			return try captureWindow(windowId: windowId)
		}
		var capture = includeImage || readText == "always" ? try capturedWindow() : nil

		guard let window = requestedRoot else {
			guard let menuWindowId = cgMenuWindowId(rootRef), let menuPid = pidForWindowId(menuWindowId) else {
				throw BridgeFailure(message: "Root reference is stale. Call find-roots again.", code: "root_not_found")
			}
			ensureEnhancedAccessibility(pid: menuPid)
			return cgMenuLook(rootRef: rootRef, windowId: menuWindowId, capturedAt: captureStart)
		}
		guard let pid = pidForElement(window) else {
			throw BridgeFailure(message: "Root reference is stale. Call find-roots again.", code: "root_not_found")
		}
		ensureEnhancedAccessibility(pid: pid)
		let rootElement: AXUIElement
		let scopeRef = optionalStringArg(request, "scopeRef")
		if let scopeRef {
			guard let scoped = refStore.element(for: scopeRef), isElement(scoped, descendantOf: window) else {
				throw BridgeFailure(message: "Scope ref is stale or outside the target root", code: "element_ref_invalid")
			}
			rootElement = scoped
		} else {
			rootElement = window
		}

		let rootFrame = frameForWindow(window)
		/// Outline coordinates follow the captured image when there is one, else the window in points.
		func geometry() -> (width: Int, height: Int, image: CGImage?, transform: (CGRect) -> CGRect) {
			guard let capture else {
				let width = max(1, Int(rootFrame.width))
				let height = max(1, Int(rootFrame.height))
				return (width, height, nil, rectTransform(windowFrame: rootFrame, imageWidth: width, imageHeight: height))
			}
			let image = downscaledImage(capture.image, maxDimension: maxDimension) ?? capture.image
			return (image.width, image.height, image, rectTransform(windowFrame: capture.frame, imageWidth: image.width, imageHeight: image.height))
		}
		let describeStart = Date()
		var frame = geometry()
		var outline = buildLookOutline(root: rootElement, transform: frame.transform)
		// A window that says (almost) nothing through Accessibility is read from the screen,
		// so the same observe → act loop still has something to act on.
		let readsScreen = readText == "always" || (readText == "auto" && scopeRef == nil && accessibleContentCount(outline, windowTitle: stringAttribute(window, attribute: kAXTitleAttribute as CFString) ?? "") < Self.sparseContentLimit)
		var describeMs = elapsedMs(describeStart)
		if readsScreen && capture == nil, let captured = try capturedWindow() {
			capture = captured
			frame = geometry()
			let redescribeStart = Date()
			outline = buildLookOutline(root: rootElement, transform: frame.transform)
			describeMs += elapsedMs(redescribeStart)
		}
		let imageWidth = frame.width
		let imageHeight = frame.height
		var imagePayload: [String: Any]?
		// OCR nodes are pressed by coordinates, and coordinates need the image they belong to.
		if let image = frame.image, includeImage || readsScreen {
			guard let jpeg = jpegData(image: image, quality: 0.8) else {
				throw BridgeFailure(message: "Failed to encode look image as JPEG", code: "encoding_failed")
			}
			imagePayload = ["jpegBase64": jpeg.base64EncodedString(), "width": image.width, "height": image.height]
		}

		var readTextMs = 0
		var readTextExecuted = false
		if let capture, readsScreen {
			readTextExecuted = true
			let textStart = Date()
			let boxes = try recognizeText(in: capture.image, outputWidth: imageWidth, outputHeight: imageHeight)
			attachOCR(boxes, to: outline)
			readTextMs = elapsedMs(textStart)
		}

		let lookId = freshLookId()
		let baseRecord = baseLookId.flatMap { lookRecord(for: $0) }
		storeLookRecord(LookRecord(
			lookId: lookId,
			windowId: windowId ?? baseRecord?.windowId ?? 0,
			windowFrame: baseRecord?.windowFrame ?? capture?.frame ?? rootFrame,
			imageWidth: baseRecord?.imageWidth ?? imageWidth,
			imageHeight: baseRecord?.imageHeight ?? imageHeight,
			hasImage: baseRecord?.hasImage ?? (capture != nil)
		))
		let scale = (capture?.frame.width ?? rootFrame.width) > 0 ? Double(imageWidth) / (capture?.frame.width ?? rootFrame.width) : displayScaleFactor(for: rootFrame)
		let pairing = pairingForWindow(window, pid: pid)
		let role = stringAttribute(window, attribute: kAXRoleAttribute as CFString) ?? ""
		let subrole = stringAttribute(window, attribute: kAXSubroleAttribute as CFString) ?? ""
		let sheetCount = sheetElements(of: window).count
		var response: [String: Any] = [
			"lookId": lookId,
			"capturedAt": captureStart.timeIntervalSince1970,
			"window": [
				"windowId": Int(windowId ?? 0),
				"rootRef": rootRef,
				"kind": rootKind(role: role, subrole: subrole),
				"framePoints": ["x": (capture?.frame ?? rootFrame).origin.x, "y": (capture?.frame ?? rootFrame).origin.y, "w": (capture?.frame ?? rootFrame).width, "h": (capture?.frame ?? rootFrame).height],
				"scaleFactor": scale,
				"isModal": (boolAttribute(window, attribute: "AXModal" as CFString) ?? false) || sheetCount > 0 || isDialogLikeRoot(role: role, subrole: subrole),
				"metadata": rootMetadata(pairing: pairing, sheetCount: sheetCount),
				"role": role,
				"subrole": subrole,
			],
			"outline": outline.payload(),
			"timings": ["captureMs": captureMs, "describeMs": describeMs, "readTextMs": readTextMs],
			"readText": ["requested": readText, "executed": readTextExecuted],
		]
		if let imagePayload { response["image"] = imagePayload }
		return response
	}

	func storeLookRecord(_ record: LookRecord) {
		lookRecordLock.lock()
		defer { lookRecordLock.unlock() }
		lookRecords[record.lookId] = record
		lookRecordOrder.append(record.lookId)
		while lookRecordOrder.count > 8 {
			let oldest = lookRecordOrder.removeFirst()
			lookRecords.removeValue(forKey: oldest)
		}
	}

	func freshLookId() -> String {
		lookRecordLock.lock()
		defer { lookRecordLock.unlock() }
		nextLookId += 1
		return "look_\(nextLookId)"
	}

	func lookRecord(for lookId: String) -> LookRecord? {
		lookRecordLock.lock()
		defer { lookRecordLock.unlock() }
		return lookRecords[lookId]
	}

	func rectTransform(windowFrame: CGRect, imageWidth: Int, imageHeight: Int) -> (CGRect) -> CGRect {
		let sx = windowFrame.width > 0 ? Double(imageWidth) / windowFrame.width : 1.0
		let sy = windowFrame.height > 0 ? Double(imageHeight) / windowFrame.height : 1.0
		return { frame in
			let x = (frame.origin.x - windowFrame.origin.x) * sx
			let y = (frame.origin.y - windowFrame.origin.y) * sy
			let w = frame.width * sx
			let h = frame.height * sy
			return self.clampRect(CGRect(x: x, y: y, width: w, height: h), width: imageWidth, height: imageHeight)
		}
	}

	func clampRect(_ rect: CGRect, width: Int, height: Int) -> CGRect {
		let maxX = Double(width)
		let maxY = Double(height)
		let x1 = min(max(rect.minX, 0), maxX)
		let y1 = min(max(rect.minY, 0), maxY)
		let x2 = min(max(rect.maxX, 0), maxX)
		let y2 = min(max(rect.maxY, 0), maxY)
		return CGRect(x: x1, y: y1, width: max(0, x2 - x1), height: max(0, y2 - y1))
	}

	func buildLookOutline(root: AXUIElement, transform: @escaping (CGRect) -> CGRect) -> LookNode {
		let rootNode = lookNode(element: root, transform: transform, offscreen: false)
		let nodeLimit = 2000
		// Apps with slow AX servers (e.g. Outlook) can take >30s to describe; the
		// client aborts at 33s, so stop walking well before that and return a
		// truncated outline instead.
		let deadline = Date().addingTimeInterval(20.0)
		var walked = 1
		var seen = Set<ObjectIdentifier>([ObjectIdentifier(root)])
		var queue: [(AXUIElement, LookNode)] = [(root, rootNode)]
		var index = 0
		while index < queue.count {
			let (element, node) = queue[index]
			index += 1
			let children = axElementArray(element, attribute: kAXChildrenAttribute as CFString)
			if children.isEmpty { continue }
			if walked >= nodeLimit || Date() >= deadline {
				node.truncated = true
				continue
			}
			let visibleByKind = visibleChildrenByKind(element)
			for child in children {
				if walked >= nodeLimit || Date() >= deadline {
					node.truncated = true
					break
				}
				let identity = ObjectIdentifier(child)
				if seen.contains(identity) { continue }
				seen.insert(identity)
				let role = stringAttribute(child, attribute: kAXRoleAttribute as CFString) ?? ""
				let offscreen = childOffscreen(child, role: role, visibleByKind: visibleByKind)
				let childNode = lookNode(element: child, transform: transform, offscreen: offscreen)
				node.children.append(childNode)
				queue.append((child, childNode))
				walked += 1
			}
		}
		return rootNode
	}

	func lookNode(element: AXUIElement, transform: (CGRect) -> CGRect, offscreen: Bool) -> LookNode {
		let role = stringAttribute(element, attribute: kAXRoleAttribute as CFString) ?? ""
		let subrole = stringAttribute(element, attribute: kAXSubroleAttribute as CFString) ?? ""
		let actions = actionNames(element)
		var valueSettable = DarwinBoolean(false)
		let valueStatus = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable)
		var focusedSettable = DarwinBoolean(false)
		let focusedStatus = AXUIElementIsAttributeSettable(element, kAXFocusedAttribute as CFString, &focusedSettable)
		let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXTextView", "AXSearchField", "AXComboBox", "AXEditableText", "AXSecureTextField"]
		let title = stringAttribute(element, attribute: kAXTitleAttribute as CFString) ?? ""
		let description = stringAttribute(element, attribute: kAXDescriptionAttribute as CFString) ?? ""
		let value = displayValue(element, role: role, subrole: subrole)
		let screenRect = frameForElement(element) ?? .zero
		let node = LookNode(
			element: element,
			ref: refStore.storeElement(element, snapshot: AXRefStore.Snapshot(
				role: role,
				identifier: stringAttribute(element, attribute: "AXIdentifier" as CFString) ?? "",
				label: normalizedLabel([title, description, value].joined(separator: " ")),
				rect: screenRect
			)),
			role: role,
			subrole: subrole,
			identifier: stringAttribute(element, attribute: "AXIdentifier" as CFString) ?? "",
			title: title,
			description: description,
			value: value,
			actions: actions,
			canPress: actions.contains(kAXPressAction as String),
			canFocus: focusedStatus == .success && focusedSettable.boolValue,
			canSetValue: valueStatus == .success && valueSettable.boolValue,
			canScroll: supportsAnyScrollAction(element),
			canIncrement: actions.contains(kAXIncrementAction as String),
			canDecrement: actions.contains(kAXDecrementAction as String),
			isTextInput: textRoles.contains(role),
			rect: transform(screenRect),
			focused: boolAttribute(element, attribute: kAXFocusedAttribute as CFString) == true,
			offscreen: offscreen
		)
		if node.canScroll {
			let rows = axElementArray(element, attribute: kAXRowsAttribute as CFString)
			let visibleRows = axElementArrayIfPresent(element, attribute: kAXVisibleRowsAttribute as CFString)
			if !rows.isEmpty, let visibleRows {
				node.scrollExtent = ["seen": visibleRows.count, "total": rows.count]
			}
		}
		return node
	}

	func visibleChildrenByKind(_ element: AXUIElement) -> [String: [AXUIElement]?] {
		[
			"AXRow": axElementArrayIfPresent(element, attribute: kAXVisibleRowsAttribute as CFString),
			"AXColumn": axElementArrayIfPresent(element, attribute: kAXVisibleColumnsAttribute as CFString),
			"AXCell": axElementArrayIfPresent(element, attribute: kAXVisibleCellsAttribute as CFString),
			"*": axElementArrayIfPresent(element, attribute: kAXVisibleChildrenAttribute as CFString),
		]
	}

	func childOffscreen(_ child: AXUIElement, role: String, visibleByKind: [String: [AXUIElement]?]) -> Bool {
		let key = role == "AXRow" || role == "AXColumn" || role == "AXCell" ? role : "*"
		guard let visible = visibleByKind[key] ?? nil else { return false }
		return !visible.contains { sameElement($0, child) }
	}

	/// Fewer accessible content nodes than this and the window is read from the screen.
	/// Calibrated on macOS 27: WeChat, IINA and a drawn-button window expose 0 below their
	/// window chrome, a Ghostty terminal 3, TextEdit about 40, a Chrome window 16 or more.
	static let sparseContentLimit = 2

	/// Nodes below the window chrome that name something or can be acted on. The traffic
	/// light buttons and the title bar's own icon and title text say nothing about content.
	func accessibleContentCount(_ root: LookNode, windowTitle: String) -> Int {
		var count = 0
		func visit(_ node: LookNode) {
			for child in node.children where count < Self.sparseContentLimit {
				let label = [child.title, child.description, child.value].first { !$0.isEmpty } ?? ""
				let titleBar = ["AXStaticText", "AXImage"].contains(child.role) && !label.isEmpty && windowTitle.contains(label)
				let actionable = child.canPress || child.canSetValue || child.canScroll || child.isTextInput
				if !windowControls.contains(child.subrole), !titleBar, !label.isEmpty || actionable { count += 1 }
				visit(child)
			}
		}
		visit(root)
		return count
	}

	func lookPoint(record: LookRecord, x: Double, y: Double) -> CGPoint {
		let relX = min(max(x / max(1.0, Double(record.imageWidth)), 0), 1)
		let relY = min(max(y / max(1.0, Double(record.imageHeight)), 0), 1)
		return CGPoint(x: record.windowFrame.origin.x + record.windowFrame.width * relX, y: record.windowFrame.origin.y + record.windowFrame.height * relY)
	}

	func payloadNode(element: AXUIElement) -> [String: Any] {
		let node = lookNode(element: element, transform: { $0 }, offscreen: false)
		var payload = node.payload()
		payload["children"] = []
		return payload
	}

	func hitTest(_ request: [String: Any]) throws -> [String: Any] {
		let lookId = try stringArg(request, "lookId")
		guard let record = lookRecord(for: lookId) else {
			throw BridgeFailure(message: "Look id '\(lookId)' is no longer available", code: "stale_look")
		}
		let point = lookPoint(record: record, x: try doubleArg(request, "x"), y: try doubleArg(request, "y"))
		guard let element = hitTestElement(at: point) else {
			throw BridgeFailure(message: "No element at point", code: "hit_test_failed")
		}
		return payloadNode(element: element)
	}
}
