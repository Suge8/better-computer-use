import AppKit
import BCUCore

/// Names the picture-only root of a popup menu Accessibility never exposed.
let popupMenuName = "cgmenu:"

extension Platform {
	/// A popup menu Accessibility never exposed still has screen geometry, so callers get a
	/// picture-only root rather than a failure they cannot act on.
	func popupMenuLook(windowId: UInt32, capturedAt: Date) -> LookResult {
		let frame = windowInfo(windowId: windowId)?.bounds ?? CGRect(x: 0, y: 0, width: 1, height: 1)
		let outline = LookNode(handle: nil, name: "\(popupMenuName)\(windowId)", role: "AXMenu", subrole: "", identifier: "", title: "Menu", description: "", value: "", actions: [], canPress: false, canFocus: false, canSetValue: false, canScroll: false, canIncrement: false, canDecrement: false, isTextInput: false, rect: CGRect(x: 0, y: 0, width: max(1, frame.width), height: max(1, frame.height)), pictureOnly: true)
		return LookResult(
			capturedAt: capturedAt,
			window: LookWindow(windowId: windowId, kind: .menu, framePoints: frame, scaleFactor: displayScaleFactor(for: frame), isModal: false, metadata: RootMetadata(pairing: RootPairing(confidence: .low, score: 0), sheetCount: 0), role: "AXMenu", subrole: ""),
			outline: outline,
			geometry: LookGeometry(windowId: windowId, windowFrame: frame, imageWidth: max(1, Int(frame.width)), imageHeight: max(1, Int(frame.height)), hasImage: false),
			timings: LookTimings(captureMs: 0, describeMs: 0, readTextMs: 0),
			readText: nil,
			image: nil
		)
	}

	/// Observes one root: its accessibility outline, and its picture and the text read from
	/// it when asked or when Accessibility says too little.
	public func look(_ request: LookRequest) throws -> sending LookResult {
		let windowId = request.windowId
		let maxDimension = request.maxDimension.map { max(1, $0) }
		let readText = request.readText
		let includeImage = request.includeImage

		let requestedRoot: AXUIElement?
		let popupMenuWindowId: UInt32?
		switch request.root.rootObject {
		case .element(let element): (requestedRoot, popupMenuWindowId) = (element.element, nil)
		case .popupMenu(let windowId): (requestedRoot, popupMenuWindowId) = (nil, windowId)
		case nil: (requestedRoot, popupMenuWindowId) = (nil, nil)
		}
		let requestedRole = requestedRoot.flatMap { stringAttribute($0, attribute: kAXRoleAttribute as CFString) } ?? ""
		let isMenuRoot = requestedRole == "AXMenu" || popupMenuWindowId != nil
		let captureStart = Date()
		var captureMs = 0
		func capturedWindow() throws -> CapturedWindowImage? {
			guard !isMenuRoot, let windowId else { return nil }
			let started = Date()
			defer { captureMs = elapsedMs(started) }
			return try captureWindow(windowId: windowId).capture
		}
		var capture = includeImage || readText == .always ? try capturedWindow() : nil

		guard let window = requestedRoot else {
			guard let menuWindowId = popupMenuWindowId, let menuPid = pidForWindowId(menuWindowId) else {
				throw BCUError(.windowStale, "Root reference is stale. Call find-roots again.")
			}
			ensureEnhancedAccessibility(pid: menuPid)
			return popupMenuLook(windowId: menuWindowId, capturedAt: captureStart)
		}
		guard let pid = pidForElement(window) else {
			throw BCUError(.windowStale, "Root reference is stale. Call find-roots again.")
		}
		ensureEnhancedAccessibility(pid: pid)
		let rootElement: AXUIElement
		let scope = request.scope
		if let scope {
			guard let scoped = scope.elementRecord?.element.element, isElement(scoped, descendantOf: window) else {
				throw BCUError(.elementNotFound, "Scope ref is stale or outside the target root")
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
		let readsScreen = readText == .always || (readText == .auto && scope == nil && accessibleContentCount(outline, windowTitle: stringAttribute(window, attribute: kAXTitleAttribute as CFString) ?? "") < Self.sparseContentLimit)
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
		var image: LookImage?
		// OCR nodes are pressed by coordinates, and coordinates need the image they belong to.
		if let picture = frame.image, includeImage || readsScreen {
			guard let jpeg = jpegData(image: picture, quality: 0.8) else {
				throw BCUError(.internalError, "Failed to encode look image as JPEG")
			}
			image = LookImage(jpeg: jpeg, width: picture.width, height: picture.height)
		}

		var readTextMs = 0
		var readTextExecuted = false
		if let capture, readsScreen {
			readTextExecuted = true
			let textStart = Date()
			let boxes = try recognizeText(in: capture.image, pixelsPerPoint: Double(capture.image.width) / capture.frame.width, outputWidth: imageWidth, outputHeight: imageHeight)
			attachOCR(boxes, to: outline)
			readTextMs = elapsedMs(textStart)
		}

		let base = request.baseGeometry
		let geometry = LookGeometry(
			windowId: windowId ?? base?.windowId ?? 0,
			windowFrame: base?.windowFrame ?? capture?.frame ?? rootFrame,
			imageWidth: base?.imageWidth ?? imageWidth,
			imageHeight: base?.imageHeight ?? imageHeight,
			hasImage: base?.hasImage ?? (capture != nil)
		)
		let scale = (capture?.frame.width ?? rootFrame.width) > 0 ? Double(imageWidth) / (capture?.frame.width ?? rootFrame.width) : displayScaleFactor(for: rootFrame)
		let pairing = pairingForWindow(window, pid: pid)
		let role = stringAttribute(window, attribute: kAXRoleAttribute as CFString) ?? ""
		let subrole = stringAttribute(window, attribute: kAXSubroleAttribute as CFString) ?? ""
		let sheetCount = sheetElements(of: window).count
		return LookResult(
			capturedAt: captureStart,
			window: LookWindow(
				windowId: windowId ?? 0,
				kind: rootKind(role: role, subrole: subrole),
				framePoints: capture?.frame ?? rootFrame,
				scaleFactor: scale,
				isModal: (boolAttribute(window, attribute: "AXModal" as CFString) ?? false) || sheetCount > 0 || isDialogLikeRoot(role: role, subrole: subrole),
				metadata: rootMetadata(pairing: pairing, sheetCount: sheetCount),
				role: role,
				subrole: subrole
			),
			outline: outline,
			geometry: geometry,
			timings: LookTimings(captureMs: captureMs, describeMs: describeMs, readTextMs: readTextMs),
			readText: (readText, readTextExecuted),
			image: image
		)
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
		let identifier = stringAttribute(element, attribute: "AXIdentifier" as CFString) ?? ""
		let node = LookNode(
			handle: .element(element, snapshot: ElementSnapshot(
				role: role,
				identifier: identifier,
				label: normalizedLabel([title, description, value].joined(separator: " ")),
				rect: screenRect
			)),
			name: "",
			role: role,
			subrole: subrole,
			identifier: identifier,
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
				node.scrollExtent = ScrollExtent(seen: visibleRows.count, total: rows.count)
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

	func lookPoint(_ geometry: LookGeometry, x: Double, y: Double) -> CGPoint {
		let relX = min(max(x / max(1.0, Double(geometry.imageWidth)), 0), 1)
		let relY = min(max(y / max(1.0, Double(geometry.imageHeight)), 0), 1)
		return CGPoint(x: geometry.windowFrame.origin.x + geometry.windowFrame.width * relX, y: geometry.windowFrame.origin.y + geometry.windowFrame.height * relY)
	}
}
