import AppKit

let args = CommandLine.arguments
if DebugCLI.handles(args) { DebugCLI.run(args) }   // never returns

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: AppController!
    var menuBar: MenuBarController!
    func applicationDidFinishLaunching(_ n: Notification) {
        controller = AppController()
        menuBar = MenuBarController(app: controller)
        Settings.shared.enableLaunchAtLoginOnFirstRun()
        controller.start()
        menuBar.showWelcomeOnce()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
