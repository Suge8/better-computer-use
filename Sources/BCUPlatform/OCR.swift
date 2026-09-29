import Vision
import BCUCore

extension Platform {
	/// Without languages Vision reads Latin script only, and a Chinese interface comes back empty.
	static let ocrLanguages = ["zh-Hans", "zh-Hant", "en-US"]
	/// Vision misreads interface-size CJK glyphs captured at one pixel per point (a 20 pt label
	/// comes back as other characters or not at all); at two pixels per point, what a Retina
	/// display captures, it reads them. A capture below that is scaled up before recognition.
	static let ocrPixelsPerPoint = 2.0

	/// `pixelsPerPoint` is the capture's resolution; the boxes are in `outputWidth` × `outputHeight`.
	func recognizeText(in capture: CGImage, pixelsPerPoint: Double, outputWidth: Int, outputHeight: Int) throws -> [OCRBox] {
		let image = pixelsPerPoint < Self.ocrPixelsPerPoint ? try scaled(capture, by: Self.ocrPixelsPerPoint / pixelsPerPoint) : capture
		let request = VNRecognizeTextRequest()
		request.recognitionLevel = .accurate
		request.recognitionLanguages = Self.ocrLanguages
		request.usesLanguageCorrection = false
		// `perform` runs the request to completion before it returns.
		do {
			try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
		} catch {
			throw BCUError(.actionFailed, "Text recognition failed: \(error.localizedDescription)")
		}
		return (request.results ?? []).compactMap { observation in
			guard let candidate = observation.topCandidates(1).first else { return nil }
			let box = observation.boundingBox
			let x = box.origin.x * Double(outputWidth)
			let y = (1.0 - box.origin.y - box.height) * Double(outputHeight)
			let w = box.width * Double(outputWidth)
			let h = box.height * Double(outputHeight)
			return OCRBox(string: candidate.string, confidence: Double(candidate.confidence), rect: CGRect(x: x, y: y, width: w, height: h))
		}
	}

	/// Vision reports boxes relative to the image, so scaling moves none of them.
	private func scaled(_ image: CGImage, by factor: Double) throws -> CGImage {
		let width = Int((Double(image.width) * factor).rounded()), height = Int((Double(image.height) * factor).rounded())
		guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
			throw BCUError(.internalError, "Failed to scale the capture for text recognition")
		}
		context.interpolationQuality = .high
		context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
		guard let result = context.makeImage() else { throw BCUError(.internalError, "Failed to scale the capture for text recognition") }
		return result
	}
}
