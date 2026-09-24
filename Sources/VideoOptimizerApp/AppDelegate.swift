import Cocoa
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var settingsController: SettingsWindowController?
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()

        // Sleep prevention during encodes (§4.2)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Encoding video"
        )

        let mainVC = MainViewController()
        mainVC.view.frame = NSRect(x: 0, y: 0, width: 720, height: 560)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VideoOptimizer"
        window.contentViewController = mainVC
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About VideoOptimizer",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…",
                        action: #selector(showSettings(_:)),
                        keyEquivalent: ",")
        appMenu.addItem(withTitle: "Hide VideoOptimizer",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit VideoOptimizer",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…",
                         action: #selector(openFilesDialog(_:)),
                         keyEquivalent: "o")
        fileMenu.addItem(.separator())
        // No target: routed down the responder chain to MainViewController, which
        // enables the item only while something is actually running.
        let stopItem = NSMenuItem(title: "Stop Converting",
                                  action: #selector(MainViewController.stopConverting(_:)),
                                  keyEquivalent: ".")
        stopItem.keyEquivalentModifierMask = [.command]
        fileMenu.addItem(stopItem)
        fileMenuItem.submenu = fileMenu

        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "VideoOptimizer Help",
                         action: #selector(openHelp(_:)),
                         keyEquivalent: "")
        helpMenuItem.submenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    @MainActor
    @objc func showSettings(_ sender: Any?) {
        if settingsController == nil {
            settingsController = SettingsWindowController()
        }
        settingsController?.showWindow(nil)
        settingsController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openFilesDialog(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Optimize"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls.filter { url in
            url.hasDirectoryPath || DropZoneView.isVideo(url)
        }
        guard !urls.isEmpty else { return }
        NotificationCenter.default.post(name: .init("VideoOptimizerFilesDropped"), object: urls)
    }

    @objc private func openHelp(_ sender: Any?) {
        if let url = URL(string: "https://www.google.com/search?q=videooptimizer+help") {
            NSWorkspace.shared.open(url)
        }
    }

    // Dock file-drop handling
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        NotificationCenter.default.post(name: .init("VideoOptimizerFilesDropped"), object: urls)
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}