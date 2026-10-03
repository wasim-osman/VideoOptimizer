import Cocoa
import AppKit
import VideoOptimizerCore

/// The whole main window: a drop target and nothing else.
/// Dropping starts encoding immediately — no confirmation, no queue list (spec §5.1).
@MainActor
final class MainViewController: NSViewController, NSMenuItemValidation {

    private let dropZone = DropZoneView()
    private var queue: JobQueue
    private var queueConcurrency: Int
    private var pollTimer: Timer?
    private var lastOutputURL: URL?
    private var hasAnnouncedDrain = true
    /// Every job ID whose outcome has already been folded into LifetimeStatsStore, so a
    /// completed job is counted exactly once no matter how many times the 0.4s poll
    /// timer sees it sitting there afterward.
    private var recordedJobIDs: Set<UUID> = []

    init() {
        let settings = SettingsStore.shared.settings
        self.queueConcurrency = settings.concurrency
        self.queue = JobQueue(maxConcurrent: settings.concurrency, settings: settings)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        dropZone.frame = NSRect(x: 0, y: 0, width: 440, height: 300)
        dropZone.autoresizingMask = [.width, .height]
        dropZone.onDrop = { [weak self] urls in self?.enqueue(urls) }
        dropZone.onClick = { [weak self] in self?.revealLastOutput() }
        dropZone.onDoubleClick = { NSApp.sendAction(#selector(AppDelegate.openFilesDialog(_:)), to: NSApp.delegate, from: nil) }
        dropZone.onSettingsButtonTapped = { NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: NSApp.delegate, from: nil) }
        dropZone.onStopButtonTapped = { [weak self] in self?.stopConverting(nil) }
        view = dropZone
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: SettingsStore.didChange, object: nil
        )

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refresh()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        pollTimer?.invalidate()
        pollTimer = nil
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Input

    /// Entry point for files opened outside a drag: the Dock, Finder's "Open With",
    /// double-clicking a video with this app as the default handler, or File ▸ Open…
    /// A direct call from AppDelegate rather than a notification — see AppDelegate's
    /// pendingOpenURLs for why a notification here was fragile at launch time.
    func enqueueExternally(_ urls: [URL]) {
        enqueue(urls.filter(DropZoneView.isVideo))
    }

    private func enqueue(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        hasAnnouncedDrain = false
        Task { @MainActor in
            await adoptPendingConcurrencyIfIdle()
            let allJobs = await queue.snapshot()
            // macOS can deliver one window-drop through BOTH the drag handler and
            // application(_:openFiles:) — de-duplicate so one file = one job. Only
            // against jobs still actually in flight: a cancelled, failed, or even
            // succeeded job must not block that same file from ever being re-dropped
            // again in this session — re-dropping the file you just cancelled is a
            // completely reasonable thing to do, and used to be silently ignored.
            var seen = Set(allJobs.filter { Self.isActive($0.state) }.map { $0.inputURL.standardizedFileURL })
            for url in urls {
                let key = url.standardizedFileURL
                guard !seen.contains(key) else { continue }
                seen.insert(key)

                // This exact file was already refused once (already efficient, or a
                // re-encode would have been bigger) — ask before trying again rather
                // than silently repeating the same refusal.
                if let refused = ForceConvert.shouldPromptToForce(url: url, among: allJobs) {
                    guard confirmForceConvert(fileName: url.lastPathComponent, reason: refused.error) else { continue }
                    await queue.addJob(url: url, forceEncode: true)
                } else {
                    await queue.addJob(url: url)
                }
            }
            refresh()
        }
    }

    /// "Convert anyway?" after a file was already refused once. Modal and synchronous —
    /// the same pattern Settings already uses for its one confirmation (deleteSource) —
    /// since this needs the user's answer before deciding whether to enqueue anything.
    private func confirmForceConvert(fileName: String, reason: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Convert \"\(fileName)\" anyway?"
        alert.informativeText = "\(reason)\n\nConverting it again will still run, but it may not save "
            + "space, and re-encoding it loses a little quality each time."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Convert Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// `JobQueue` fixes its concurrency at init, so a changed setting takes effect
    /// on the next drop that arrives while nothing is running.
    private func adoptPendingConcurrencyIfIdle() async {
        let desired = SettingsStore.shared.settings.concurrency
        guard desired != queueConcurrency else { return }
        let busy = await queue.snapshot().contains { Self.isActive($0.state) }
        guard !busy else { return }
        queueConcurrency = desired
        queue = JobQueue(maxConcurrent: desired, settings: SettingsStore.shared.settings)
    }

    @objc private func settingsChanged() {
        let settings = SettingsStore.shared.settings
        Task { await queue.setSettings(settings) }
    }

    // MARK: - Cancelling

    /// File ▸ Stop Converting (⌘.). Reaches the live ffmpeg process, which is asked
    /// to finalise what it has written and then killed if it does not.
    @objc func stopConverting(_ sender: Any?) {
        Task { @MainActor in
            await queue.cancelAll()
            refresh()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(stopConverting(_:)) else { return true }
        return hasActiveJobs
    }

    /// Mirrors the queue so menu validation stays synchronous; refreshed on each poll.
    private var hasActiveJobs = false

    /// Whether quitting right now would need to be confirmed. Not a live query — it's
    /// the same up-to-0.4s-stale flag menu validation already relies on, which is fine
    /// for deciding whether to show a warning dialog.
    var hasJobsWorthWarningAboutOnQuit: Bool { hasActiveJobs }

    /// Called only when the app itself is quitting with jobs still running: cancels
    /// everything and waits briefly for ffmpeg to actually exit, so a quit — unlike a
    /// force-quit or crash — never leaves an orphaned encode with nothing able to see
    /// or stop it. Returns once every job is out of an active state, or after a bounded
    /// wait if something doesn't stop in time.
    func stopAllJobsForQuit() async {
        await queue.cancelAll()
        // FFmpegRunner's own escalation is 'q' -> 3s -> SIGINT -> 2s -> SIGKILL, so this
        // needs real margin beyond 5s to reliably outlast it rather than racing it.
        let deadline = Date().addingTimeInterval(7)
        while Date() < deadline {
            let jobs = await queue.snapshot()
            guard jobs.contains(where: { Self.isActive($0.state) }) else { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    override func keyDown(with event: NSEvent) {
        // Esc is the other conventional way out of a long operation.
        if event.keyCode == 53, hasActiveJobs {
            stopConverting(nil)
            return
        }
        super.keyDown(with: event)
    }

    private func revealLastOutput() {
        guard let url = lastOutputURL, FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Status line

    private func refresh() {
        guard view.window != nil else { return }
        Task { @MainActor in
            let jobs = await queue.snapshot()
            render(jobs)
        }
    }

    private func render(_ jobs: [Job]) {
        defer { dropZone.setStopButtonVisible(hasActiveJobs) }
        recordNewlySucceededJobs(jobs)

        guard !jobs.isEmpty else {
            hasActiveJobs = false
            dropZone.show(.init(headline: "Drop video files here", detail: "", progress: nil,
                                lifetimeCaption: lifetimeCaption()))
            return
        }

        let active = jobs.filter { Self.isActive($0.state) }
        hasActiveJobs = !active.isEmpty
        lastOutputURL = jobs.last(where: { $0.state == .succeeded })?.resultURL ?? lastOutputURL

        if let current = active.first(where: { $0.state == .encoding }) ?? active.first {
            let done = jobs.count - active.count
            let headline = jobs.count == 1
                ? "Converting…"
                : "Converting \(min(done + 1, jobs.count)) of \(jobs.count)"

            var parts = [current.inputURL.lastPathComponent]
            if current.state == .encoding {
                parts.append(String(format: "%.0f%%", current.progress * 100))
            } else {
                parts.append(current.state == .probing ? "analysing" : "planning")
            }
            if !current.speedText.isEmpty { parts.append(current.speedText) }
            if !current.etaText.isEmpty { parts.append(current.etaText) }

            // Name whatever is waiting behind the current job — otherwise a second
            // drop while busy is queued correctly but invisible, and looks like it
            // did nothing.
            let queued = jobs.filter { $0.state == .queued && $0.id != current.id }
            if let next = queued.first {
                let extra = queued.count - 1
                parts.append(extra > 0
                    ? "next: \(next.inputURL.lastPathComponent) (+\(extra))"
                    : "next: \(next.inputURL.lastPathComponent)")
            }

            let overall = jobs.reduce(0.0) { $0 + $1.progress } / Double(jobs.count)
            dropZone.show(.init(headline: headline, detail: parts.joined(separator: " · "), progress: overall))
            return
        }

        announceDrainIfNeeded()
        dropZone.show(.init(headline: IdleSummary.headline(for: jobs), detail: IdleSummary.detail(for: jobs),
                            progress: nil, lifetimeCaption: lifetimeCaption()))
    }

    /// Folds every newly-succeeded job's before/after sizes into the persisted lifetime
    /// total exactly once. Only genuine `.succeeded` conversions count — a job that was
    /// already optimised or discarded as not-worth-keeping never touched a real output
    /// file, so it saved nothing.
    private func recordNewlySucceededJobs(_ jobs: [Job]) {
        for job in jobs where job.state == .succeeded && !recordedJobIDs.contains(job.id) {
            recordedJobIDs.insert(job.id)
            guard let resultSize = job.resultSize else { continue }
            LifetimeStatsStore.shared.record(inputBytes: job.inputSize, outputBytes: resultSize)
        }
    }

    private func lifetimeCaption() -> String {
        let stats = LifetimeStatsStore.shared.stats
        guard stats.filesConverted > 0 else { return "" }
        let filesText = stats.filesConverted == 1 ? "1 file" : "\(stats.filesConverted) files"
        return "Lifetime: \(format(stats.totalBytesSaved)) saved across \(filesText)"
    }

    private func announceDrainIfNeeded() {
        guard !hasAnnouncedDrain else { return }
        hasAnnouncedDrain = true
        if !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    private func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private static func isActive(_ state: JobState) -> Bool {
        switch state {
        case .queued, .probing, .planning, .encoding: return true
        default: return false
        }
    }
}
