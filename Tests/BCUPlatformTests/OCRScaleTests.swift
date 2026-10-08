@testable import BCUPlatform
import CoreGraphics
import Foundation
import ImageIO
import Testing

// A 1x display captures one pixel per point, and at that size Vision misreads interface
// Chinese: the platform reads such a capture as sharply as a Retina one. The sample is the
// drawn-buttons fixture drawn offscreen at two pixels per point
// (scripts/fixtures/drawn-buttons-2x.png); scaled down by half it is what a 1x display
// captures of that window.
struct OCRScaleTests {
	@Test func aCaptureAtOnePixelPerPointReadsTheDrawnLabels() throws {
		let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../scripts/fixtures/drawn-buttons-2x.png").standardizedFileURL
		let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
		let width = source.width / 2, height = source.height / 2
		let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
		context.interpolationQuality = .high
		context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
		let capture = try #require(context.makeImage())

		// The guard is against misread characters; Vision versions differ in spacing ("行 5" on CI's).
		let read = Set(try Platform(showsAgentCursor: false).recognizeText(in: capture, pixelsPerPoint: 1, outputWidth: width, outputHeight: height).map { $0.string.filter { !$0.isWhitespace } })
		#expect(read.isSuperset(of: ["发送", "取消", "静默", "行3", "行4", "行5"]), "read \(read.sorted())")
	}
}
