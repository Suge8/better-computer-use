// `bcu <command>` is the client; `bcu serve` is the resident process inside bcu.app.
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["serve"] { serve() }
exit(runClient(arguments))
