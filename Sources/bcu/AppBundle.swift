import BCUCore
import Foundation

/// `bcu.app` is the unit that is installed, versioned and launched: the resident runs as the app,
/// and a client talks to a resident only when it reports the version of the app on disk.
/// The version is `CFBundleShortVersionString`, written into Info.plist at build time from the
/// git tag (scripts/lib/package.sh).
struct App {
	let path: String
	let version: String

	/// The version of a running app's own bundle; nil for a bare executable such as a debug build.
	static var runningVersion: String? { Bundle.main.infoDictionary?[versionKey] as? String }

	/// The app this executable sits in, also when it is started through a symlink such as the
	/// one brew makes; nil for a bare executable.
	static var containing: String? {
		// …/bcu.app/Contents/MacOS/bcu
		guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
		let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
		return app.pathExtension == "app" ? app.path : nil
	}

	/// The app a client starts the resident from: `BCU_APP_PATH` when set (development and tests),
	/// otherwise the app this executable sits in, which is where a brew-linked `bcu` points.
	static func target(_ settings: Settings) throws -> App {
		guard let path = settings.appPath else {
			throw BCUError(.residentUnavailable, "This bcu is not inside bcu.app, so it does not know which app to start.", recovery: "Install it with 'brew install --cask suge8/tap/bcu', or set BCU_APP_PATH to the bcu.app to drive.")
		}
		guard let version = Bundle(path: path)?.infoDictionary?[versionKey] as? String else {
			throw BCUError(.residentUnavailable, "bcu.app is not installed at \(path).", recovery: "Install it with 'brew install --cask suge8/tap/bcu'; in a bcu checkout run scripts/install.sh.")
		}
		return App(path: path, version: version)
	}

	private static let versionKey = "CFBundleShortVersionString"
}
