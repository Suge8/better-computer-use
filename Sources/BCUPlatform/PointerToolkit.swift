import Darwin
import os

/// Toolkits that drop pointer events posted to a pid. Tk takes a click's location from the
/// hardware pointer, which a pid-posted event never moves, so the click lands wherever the
/// real pointer is; LibreOffice's VCL ignores such events altogether. Either way bcu could
/// only report the click as unverified, so these apps are clicked through the real pointer.
enum PointerToolkit: String, Sendable {
	case tk = "Tk"
	case vcl = "LibreOffice"

	/// The toolkit a mapped file belongs to, from its path.
	static func mapped(inImagePath path: String) -> PointerToolkit? {
		if path.contains("/Tk.framework/") { return .tk }
		let file = (path.split(separator: "/").last.map(String.init) ?? path).lowercased()
		if file.hasPrefix("libvclplug_osx") && file.hasSuffix(".dylib") { return .vcl }
		if file.hasPrefix("_tkinter") && file.hasSuffix(".so") { return .tk }
		guard file.hasPrefix("lib"), file.hasSuffix(".dylib") else { return nil }
		var name = file.dropFirst("lib".count)
		// Tk 9 carries the Tcl major version in its name: libtcl9tk9.0.dylib.
		if name.hasPrefix("tcl") {
			name = name.dropFirst("tcl".count).drop { $0.isNumber }
		}
		return name.hasPrefix("tk") && name.dropFirst("tk".count).first?.isNumber == true ? .tk : nil
	}

	/// The toolkit mapped into `pid`, read from the files its address space maps; no task
	/// port is needed. A process is looked at once: the answer is kept for as long as that
	/// process lives.
	static func detect(pid: Int32) -> PointerToolkit? {
		guard let started = startTime(pid: pid) else { return nil }
		let key = Identity(pid: pid, started: started)
		if let known = known.withLock({ $0[key] }) { return known.toolkit }
		let found = mappedToolkit(pid: pid)
		known.withLock { $0[key] = Detected(toolkit: found) }
		return found
	}

	private struct Identity: Hashable { let pid: Int32; let started: UInt64 }
	private struct Detected { let toolkit: PointerToolkit? }
	private static let known = OSAllocatedUnfairLock(initialState: [Identity: Detected]())
	/// Bounds the walk, so a pathological address space cannot stall a click.
	private static let regionLimit = 65_536

	private static func startTime(pid: Int32) -> UInt64? {
		var info = proc_bsdinfo()
		let size = Int32(MemoryLayout<proc_bsdinfo>.size)
		guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
		return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
	}

	/// Same walk as PROC_PIDREGIONPATHINFO, but only over the regions backed by files.
	private static let fileRegionFlavor: Int32 = 22

	private static func mappedToolkit(pid: Int32) -> PointerToolkit? {
		var address: UInt64 = 0
		var info = proc_regionwithpathinfo()
		let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
		var flavor = fileRegionFlavor
		for _ in 0..<regionLimit {
			if proc_pidinfo(pid, flavor, address, &info, size) != size {
				// A kernel without the file-only flavor rejects it before reading any region.
				guard address == 0, flavor == fileRegionFlavor else { return nil }
				flavor = PROC_PIDREGIONPATHINFO
				continue
			}
			let path = withUnsafePointer(to: info.prp_vip.vip_path) {
				$0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
			}
			if let toolkit = mapped(inImagePath: path) { return toolkit }
			let next = info.prp_prinfo.pri_address &+ info.prp_prinfo.pri_size
			guard next > address else { return nil }
			address = next
		}
		return nil
	}
}
