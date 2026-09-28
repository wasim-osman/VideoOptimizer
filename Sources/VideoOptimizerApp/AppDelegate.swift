import Cocoa
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var mainViewController: MainViewController!
    private var settingsController: SettingsWindowController?
    private var activity: NSObjectProtocol?
    /// URLs that arrived via application(_:openFiles:) before mainViewController
    /// existed — a real race, not a hypothetical one: on a cold launch triggered by
    /// opening a file (double-click, Finder's Open With, `open -a … file`), AppKit
    /// does not guarantee this method fires after applicationDidFinishLaunching has
    /// finished building the window. It used to be handled by posting a notification
    /// that MainViewController's own observer picked up — but that observer is only
    /// registered in viewDidAppear(), which runs even later, so the notification could
    /// (and, confirmed by tracing it, reliably did) get posted before anyone was
    /// listening and silently vanish. A direct call has no such ordering dependency;
    /// this buffer covers the one remaining case where even the delegate itself hasn't
    /// finished constructing the view controller yet.
    private var pendingOpenURLs: [URL] = []

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
        mainViewController = mainVC

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

        if !pendingOpenURLs.isEmpty {
            mainViewController.enqueueExternally(pendingOpenURLs)
            pendingOpenURLs.removeAll()
        }
    }

    /// Without this, quitting mid-encode (⌘Q, closing the window, or the Dock menu)
    /// orphans the ffmpeg child: it keeps running, reparented to launchd, with nothing
    /// left able to see its progress, show it in any UI, or cancel it — and its output
    /// never gets renamed from .part to a final file, since that step runs in this
    /// process, not in ffmpeg itself. That combination is exactly what "the app quit
    /// but the encode kept eating CPU with no way to stop it" looks like.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard mainViewController?.hasJobsWorthWarningAboutOnQuit == true else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "A conversion is in progress"
        alert.informativeText = "Quitting now stops it. The output file will not be completed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }

        Task { @MainActor in
            await mainViewController?.stopAllJobsForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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

    @MainActor
    @objc func openFilesDialog(_ sender: Any?) {
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
        mainViewController.enqueueExternally(urls)
    }

    @objc private func openHelp(_ sender: Any?) {
        if let url = URL(string: "https://www.google.com/search?q=videooptimizer+help") {
            NSWorkspace.shared.open(url)
        }
    }

    // Dock file-drop handling
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        if let mainViewController {
            mainViewController.enqueueExternally(urls)
        } else {
            pendingOpenURLs.append(contentsOf: urls)
        }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}