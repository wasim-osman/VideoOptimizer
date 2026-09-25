import Cocoa
import AppKit
import UniformTypeIdentifiers

/// The entire UI. A dashed target that fills the window, shows one line of status,
/// and draws a hairline progress bar along its bottom edge while encoding.
final class DropZoneView: NSView {

    struct Display: Equatable {
        var headline: String
        var detail: String
        var progress: Double?   // nil hides the bar
    }

    var onDrop: (([URL]) -> Void)?
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onSettingsButtonTapped: (() -> Void)?
    var onStopButtonTapped: (() -> Void)?

    private var isTargeted = false
    private var display = Display(headline: "Drop video files here", detail: "", progress: nil)
    private let settingsButton = NSButton()
    private let stopButton = NSButton()
    private var pendingSingleClick: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
        configureSettingsButton()
        configureStopButton()
    }

    /// Shown only while a job is actually running — the menu item and ⌘. still work
    /// either way, but a control this destructive shouldn't live only behind a menu.
    func setStopButtonVisible(_ visible: Bool) {
        stopButton.isHidden = !visible
    }

    /// Mirrors the settings gear on the opposite corner: a plain stop glyph, tinted
    /// red since this is the one destructive control the window has.
    private func configureStopButton() {
        stopButton.translatesAutoresizingMaskIntoConstraints = false
        stopButton.isBordered = false
        stopButton.bezelStyle = .regularSquare
        stopButton.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: "Stop Converting")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        stopButton.imageScaling = .scaleProportionallyUpOrDown
        stopButton.contentTintColor = .systemRed
        stopButton.toolTip = "Stop Converting"
        stopButton.target = self
        stopButton.action = #selector(stopButtonClicked)
        stopButton.isHidden = true
        addSubview(stopButton)
        NSLayoutConstraint.activate([
            stopButton.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            stopButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stopButton.widthAnchor.constraint(equalToConstant: 26),
            stopButton.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    @objc private func stopButtonClicked() {
        onStopButtonTapped?()
    }

    /// A single small gear in the corner — the only chrome on an otherwise bare drop
    /// target. As a real subview it intercepts its own clicks, so it never triggers the
    /// "reveal last output" click-through the rest of the window has.
    private func configureSettingsButton() {
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.isBordered = false
        settingsButton.bezelStyle = .regularSquare
        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        settingsButton.imageScaling = .scaleProportionallyUpOrDown
        settingsButton.contentTintColor = .tertiaryLabelColor
        settingsButton.toolTip = "Settings"
        settingsButton.target = self
        settingsButton.action = #selector(settingsButtonClicked)
        addSubview(settingsButton)
        NSLayoutConstraint.activate([
            settingsButton.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            settingsButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            settingsButton.widthAnchor.constraint(equalToConstant: 26),
            settingsButton.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    @objc private func settingsButtonClicked() {
        onSettingsButtonTapped?()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { false }

    func show(_ new: Display) {
        guard new != display else { return }
        display = new
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let inset = bounds.insetBy(dx: 12, dy: 12)
        let path = NSBezierPath(roundedRect: inset, xRadius: 12, yRadius: 12)
        path.lineWidth = 2
        path.setLineDash([7, 5], count: 2, phase: 0)

        if isTargeted {
            NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
        } else {
            NSColor.separatorColor.setStroke()
        }
        path.stroke()

        let tint = isTargeted ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor
        if let glyph = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 34, weight: .light)) {
            let size = glyph.size
            let rect = NSRect(
                x: bounds.midX - size.width / 2,
                y: bounds.midY + 14,
                width: size.width,
                height: size.height
            )
            glyph.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true,
                       hints: [.interpolation: NSImageInterpolation.high.rawValue])
            tint.set()
            rect.fill(using: .sourceAtop)
        }

        draw(display.headline,
             font: .systemFont(ofSize: 13, weight: .medium),
             color: .secondaryLabelColor,
             baselineY: bounds.midY - 8)

        if !display.detail.isEmpty {
            draw(display.detail,
                 font: .systemFont(ofSize: 11, weight: .regular),
                 color: .tertiaryLabelColor,
                 baselineY: bounds.midY - 26)
        }

        if let progress = display.progress {
            let track = NSRect(x: inset.minX + 18, y: inset.minY + 16, width: inset.width - 36, height: 3)
            let trackPath = NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5)
            NSColor.separatorColor.setFill()
            trackPath.fill()

            let clamped = min(max(progress, 0), 1)
            if clamped > 0 {
                let filled = NSRect(x: track.minX, y: track.minY,
                                    width: track.width * clamped, height: track.height)
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: filled, xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
    }

    private func draw(_ text: String, font: NSFont, color: NSColor, baselineY: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: baselineY),
                                withAttributes: attrs)
    }

    /// A double click opens a file picker; a single click reveals the last output.
    /// A genuine double click still delivers a separate mouseDown for its first half
    /// (with clickCount 1) before the second one arrives with clickCount 2, so the
    /// single-click action is deferred by the system's own double-click interval and
    /// cancelled if a second click promotes it — otherwise every double click would
    /// also flash open a Finder window as a side effect of its first half.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            pendingSingleClick?.cancel()
            pendingSingleClick = nil
            onDoubleClick?()
            return
        }
        pendingSingleClick?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.onClick?() }
        pendingSingleClick = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: workItem)
    }

    // MARK: - Dragging destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isTargeted = !videoURLs(from: sender).isEmpty
        needsDisplay = true
        return isTargeted ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isTargeted = false
        needsDisplay = true
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !videoURLs(from: sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = videoURLs(from: sender)
        isTargeted = false
        needsDisplay = true
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    /// Accepts files and folders; folders are expanded one level deep (spec §5.1).
    private func videoURLs(from sender: NSDraggingInfo) -> [URL] {
        let dropped = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        var out: [URL] = []
        for url in dropped {
            if url.hasDirectoryPath {
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                out.append(contentsOf: children.filter(Self.isVideo))
            } else if Self.isVideo(url) {
                out.append(url)
            }
        }
        return out
    }

    static func isVideo(_ url: URL) -> Bool {
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return false
        }
        return type.conforms(to: .movie) || type.conforms(to: .audiovisualContent)
    }
}
