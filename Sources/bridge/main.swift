import AppKit
import BCUPlatform

_ = NSApplication.shared
NSApp.setActivationPolicy(CommandLine.arguments.contains("serve") ? .accessory : .prohibited)
Bridge().run()
