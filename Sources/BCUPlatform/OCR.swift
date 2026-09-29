import Vision

extension Platform {
	/// Without languages Vision reads Latin script only, and a Chinese interface comes back empty.
	static let ocrLanguages = ["zh-Hans", "zh-Hant", "en-US"]

	func recognizeText(in image: CGImage, outputWidth: Int, outputHeight: Int) throws -> [OCRBox] {
		let semaphore = DispatchSemaphore(value: 0)
		let recognized = Box<[OCRBox]>([])
		let recognizedError = Box<Error?>(nil)
		let request = VNRecognizeTextRequest { request, error in
			defer { semaphore.signal() }
			if let error {
				recognizedError.value = error
				return
			}
			let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
			recognized.value = observations.compactMap { observation in
				guard let candidate = observation.topCandidates(1).first else { return nil }
				let box = observation.boundingBox
				let x = box.origin.x * Double(outputWidth)
				let y = (1.0 - box.origin.y - box.height) * Double(outputHeight)
				let w = box.width * Double(outputWidth)
				let h = box.height * Double(outputHeight)
				return OCRBox(string: candidate.string, confidence: Double(candidate.confidence), rect: CGRect(x: x, y: y, width: w, height: h))
			}
		}
		request.recognitionLevel = .accurate
		request.recognitionLanguages = Self.ocrLanguages
		request.usesLanguageCorrection = false
		try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
		if semaphore.wait(timeout: .now() + .seconds(8)) == .timedOut {
			throw PlatformError(message: "Text recognition timed out", code: "text_recognition_timeout")
		}
		if let error = recognizedError.value {
			throw PlatformError(message: "Text recognition failed: \(error.localizedDescription)", code: "text_recognition_failed")
		}
		return recognized.value
	}

	/// Role of a node read from the screen. It is not an accessibility role, and the
	/// projection shows it as `ocr`.
}
