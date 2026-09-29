/// Permissions every command needs, and the two plain commands about them: doctor and setup.
import BCUCore
import BCUPlatform
import BCURuntime
import Foundation

private let grantInstructions = "Grant Accessibility and Screen Recording to bcu.app in System Settings → Privacy & Security. Screen Recording lets the agent see the window; Accessibility lets it interact with the window."

private let signingMigrationWarning = "If these permissions were enabled before this install/update, macOS invalidated the old grants because bcu.app was re-signed. Re-enable both toggles for the newly signed app. If a toggle is already on, switch it off and on again."

extension Daemon {
	/// Refuses a command until both grants are in place, saying which are missing and why a
	/// grant may not be the one this process holds.
	func ensurePermissions() async throws {
		let status = try await offload { [desktop = self.desktop] in desktop.checkPermissions() }
		let missing = [status.accessibility ? nil : "accessibility", status.screenRecording ? nil : "screenRecording"].compactMap { $0 }
		guard !missing.isEmpty else { return }
		var summary = "Accessibility: \(status.accessibility ? "granted" : "missing"); Screen Recording: \(status.screenRecording ? "granted" : "missing")"
		if status.screenRecordingPreflight && !status.screenRecording {
			summary += "; (Screen Recording reads granted in the TCC database but a live capture probe failed — the grant likely belongs to a different app identity, or bcu needs a restart.)"
		}
		let attribution = status.source.attribution == .caller
			? "Warning: bcu is not running as the installed bcu.app (executable: \(status.source.executablePath)). Grants made now would attach to the launching app instead. Restart bcu so the installed app is used."
			: nil
		let message = ["bcu is missing required macOS permissions.", summary, grantInstructions, "App: bcu.app (\(Bundle.main.bundlePath))", attribution, signingMigrationWarning].compactMap { $0 }.joined(separator: "\n")
		throw BCUError(.permissionMissing, "\(message)\nMissing permissions: \(missing.joined(separator: " and ")). Run 'bcu setup' to grant them, then retry.")
	}

	/// The resident process, its platform and the grants it holds.
	func doctor() async throws -> JSONValue {
		let (diagnostics, status) = try await offload { [desktop = self.desktop] in (desktop.diagnostics(), desktop.checkPermissions()) }
		return try JSONCoding.encode(DoctorReport(
			resident: .init(pid: Int(getpid()), protocolVersion: wireProtocolVersion),
			platform: .init(diagnostics),
			permissions: .init(status)
		))
	}

	/// Registers this process with both privacy panes, so bcu is listed there before the
	/// user is sent to grant it.
	func setup() async throws -> JSONValue {
		let registration = try await offload { [desktop = self.desktop] in desktop.registerPermissions() }
		return try JSONCoding.encode(Grants(accessibility: registration.accessibility, screenRecording: registration.screenRecording))
	}
}

private struct Grants: Encodable {
	let accessibility: Bool
	let screenRecording: Bool
}

private struct DoctorReport: Encodable {
	struct Resident: Encodable {
		let pid: Int
		let protocolVersion: Int
	}

	struct PlatformReport: Encodable {
		let arch: String
		let macOS: String
		let executablePath: String
		let pid: Int
		let parentPid: Int
		let parentPath: String?
		let parentAppName: String?
		let parentBundleId: String?

		init(_ diagnostics: Diagnostics) {
			arch = diagnostics.arch
			macOS = diagnostics.macOS
			executablePath = diagnostics.executablePath
			pid = Int(diagnostics.pid)
			parentPid = Int(diagnostics.parentPid)
			parentPath = diagnostics.parentPath
			parentAppName = diagnostics.parentAppName
			parentBundleId = diagnostics.parentBundleId
		}
	}

	struct Permissions: Encodable {
		let accessibility: Bool
		let screenRecording: Bool
		/// The per-process preflight answer; it disagrees with `screenRecording` when a grant is stale or foreign.
		let screenRecordingPreflight: Bool
		/// `bcu-app` when the grants belong to the installed bcu.app, `caller` when to whatever launched it.
		let attribution: String

		init(_ status: PermissionStatus) {
			accessibility = status.accessibility
			screenRecording = status.screenRecording
			screenRecordingPreflight = status.screenRecordingPreflight
			attribution = status.source.attribution.rawValue
		}
	}

	let resident: Resident
	let platform: PlatformReport
	let permissions: Permissions
}
