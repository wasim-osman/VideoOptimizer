import Cocoa
import AppKit

@main
enum VideoOptimizerApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}