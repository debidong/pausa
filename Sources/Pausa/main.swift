// Placeholder entry point. Mitchell owns the real app shell (state machine,
// menu bar, settings) and will replace this file. Until then it only routes
// the debug flags used to test Detection/ and Overlay/ on a real Mac.
import AppKit

let args = CommandLine.arguments
if DebugCLI.handles(args) {
    DebugCLI.run(args)   // never returns
} else {
    print("Pausa app shell not implemented yet. Try: --debug-detect | --debug-short [sec] | --debug-long [sec]")
}
