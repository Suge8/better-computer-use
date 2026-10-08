import Darwin
import os

/// Tk drops pointer events posted to a pid: it takes a click's location from the hardware
/// pointer, which a pid-posted event never moves, so the click lands wherever the real pointer
/// is and bcu could only report it as unverified. Tk apps are clicked through the real pointer.
enum Tk {
	/// Whether a mapped file is part of Tk, from its path.
	static func isImage(path: String) -> Bool {
		if path.contains("/Tk.framework/") { return true }
		let file = (path.split(separator: "/").last.map(String.init) ?? path).lowercased()
		if file.hasPrefix("_tkinter") && file.hasSuffix(".so") { return true }
		guard file.hasPrefix("lib"), file.hasSuffix(".dylib") else { return false }
		var name = file.dropFirst("lib".count)
		// Tk 9 carries the Tcl major version in its name: libtcl9tk9.0.dylib.
		if name.hasPrefix("tcl") {
			name = name.dropFirst("tcl".count).drop { $0.isNumber }
		}
		return name.hasPrefix("tk") && name.dropFirst("tk".count).first?.isNumber == true
	}

	/// Whether Tk is mapped into `pid`, read from the files its address space maps; no task
	/// port is needed. A process is looked at once: the answer is kept for as long as that
	/// process lives.
	static func isMapped(pid: Int32) -> Bool {
		guard let started = startTime(pid: pid) else { return false }
		let key = Identity(pid: pid, started: started)
		if let known = known.withLock({ $0[key] }) { return known }
		let found = mapsTk(pid: pid)
		known.withLock { $0[key] = found }
		return found
	}

	private struct Identity: Hashable { let pid: Int32; let started: UInt64 }
	private static let known = OSAllocatedUnfairLock(initialState: [Identity: Bool]())
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

	private static func mapsTk(pid: Int32) -> Bool {
		var address: UInt64 = 0
		var info = proc_regionwithpathinfo()
		let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
		var flavor = fileRegionFlavor
		for _ in 0..<regionLimit {
			if proc_pidinfo(pid, flavor, address, &info, size) != size {
				// A kernel without the file-only flavor rejects it before reading any region.
				guard address == 0, flavor == fileRegionFlavor else { return false }
				flavor = PROC_PIDREGIONPATHINFO
				continue
			}
			let path = withUnsafePointer(to: info.prp_vip.vip_path) {
				$0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
			}
			if isImage(path: path) { return true }
			let next = info.prp_prinfo.pri_address &+ info.prp_prinfo.pri_size
			guard next > address else { return false }
			address = next
		}
		return false
	}
}
