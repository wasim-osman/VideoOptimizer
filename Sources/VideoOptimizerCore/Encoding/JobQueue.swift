// JobQueue.swift - The single actor owning the encode queue (spec §1 §4.2).

import Foundation

public actor JobQueue {
    private var jobs: [UUID: Job] = [:]
    private var order: [UUID] = []
    private var active = 0
    private let maxConcurrent: Int
    private var currentSettings = Settings()
    private var sleepActivity: NSObjectProtocol?
    /// The runner for each encoding job, so a cancel can reach the live ffmpeg process.
    private var runners: [UUID: FFmpegRunner] = [:]

    public init(maxConcurrent: Int = 1,
                settings: Settings = Settings()) {
        self.maxConcurrent = maxConcurrent
        self.currentSettings = settings
    }

    public func setSettings(_ settings: Settings) async {
        currentSettings = settings
    }

    public func snapshot() -> [Job] {
        order.compactMap { jobs[$0] }
    }

    @discardableResult
    public func addJob(url: URL) async -> UUID {
        beginActivityIfNeeded()
        let job = Job(inputURL: url)
        jobs[job.id] = job
        order.append(job.id)
        drain()
        return job.id
    }

    public func job(id: UUID) -> Job? { jobs[id] }

    public func update(_ id: UUID, _ mutate: (inout Job) -> Void) {
        guard var job = jobs[id] else { return }
        mutate(&job)
        jobs[id] = job
    }

    /// Cancels a job whether it is still queued or already encoding.
    ///
    /// For a running job the state is left alone here: `process(_:)` sets `.cancelled`
    /// once ffmpeg actually exits, so the row cannot claim to be cancelled while the
    /// process is still writing.
    public func cancel(id: UUID) async {
        guard let job = jobs[id] else { return }
        if let runner = runners[id] {
            runner.cancel()
        } else if job.state == .queued || job.state == .probing || job.state == .planning {
            update(id) { $0.state = .cancelled }
        }
    }

    public func cancelAll() async {
        for id in order { await cancel(id: id) }
    }

    public func remove(id: UUID) async {
        jobs[id] = nil
        order.removeAll { $0 == id }
    }

    public func clearFinished() async {
        let finished = order.filter { jobs[$0]?.state == .succeeded || jobs[$0]?.state == .failed }
        for id in finished { jobs[id] = nil }
        order.removeAll { jobs[$0] == nil }
    }

    private func drain() {
        while active < maxConcurrent,
              let next = order.first(where: { jobs[$0]?.state == .queued }) {
            active += 1
            let id = next
            Task { await self.process(id) }
        }
    }

    private func beginActivityIfNeeded() {
        guard sleepActivity == nil else { return }
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "VideoOptimizer encoding"
        )
    }

    // MARK: - Pipeline

    private func process(_ id: UUID) async {
        guard var job = jobs[id], job.state == .queued else { active -= 1; return }

        job.state = .probing
        jobs[id] = job

        // Probe
        let probe = FFProbeService()
        let media: MediaInfo
        do {
            let info = try await probe.probe(url: job.inputURL)
            media = info
            update(id) { $0.mediaInfo = info }
        } catch {
            fail(id, message: error.localizedDescription)
            return
        }

        // Plan
        update(id) { $0.state = .planning }
        let plan = EncodePlanner().plan(media: media, settings: currentSettings)
        switch plan.outcome {
        case .alreadyOptimized(let reason), .sourceTooSmall(let reason):
            update(id) {
                $0.state = .alreadyOptimized
                $0.error = reason
                $0.progress = 1
            }
            finish(id)
            return
        case .planned:
            break
        }

        // Evaluate container change note.
        if plan.containerChanged {
            update(id) { $0.error = "Output container: \(plan.outputURL.pathExtension) (was \(job.inputURL.pathExtension))" }
        }

        // A cancel that landed while we were probing or planning must stop here,
        // before any ffmpeg process is started.
        if jobs[id]?.state == .cancelled {
            finish(id)
            return
        }

        // Encode
        update(id) { $0.state = .encoding }
        let runner = FFmpegRunner()
        runners[id] = runner
        defer { runners[id] = nil }
        let encodingStart = ContinuousClock.now   // wall-clock base for speed + ETA
        let result = await runner.run(
            arguments: plan.arguments,
            outputURL: plan.outputURL,
            inputSize: job.inputSize,
            duration: media.format.duration
        ) { percent in
            Task { await self.update(id) { $0.progress = percent } }

            // Live speed (×realtime) + ETA from wall-clock — ffmpeg's `speed=` is
            // often unreliable for VFR, so we derive it ourselves (§3.4).
            let elapsed = encodingStart.duration(to: ContinuousClock.now)
            guard elapsed > .zero else { return }
            let elapsedSeconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
            let mediaSeconds = percent * media.format.duration
            let speedX = mediaSeconds / elapsedSeconds   // realtime multiplier
            let remaining = (1 - percent) * media.format.duration
            let eta = remaining / speedX
            Task { await self.update(id) {
                $0.speedText = speedX >= 0.01 ? String(format: "%.1f× realtime", speedX) : ""
                $0.etaText = eta.isFinite && eta >= 0 ? "ETA \(Self.formatETA(eta))" : ""
            } }
        }

        switch result {
        case let r where r.cancelled:
            update(id) { $0.state = .cancelled }
            cleanPartFile(plan.outputURL)
        case let r where r.discardedAsBlob:
            update(id) {
                $0.state = .discardedAsBlob
                $0.error = r.message
                $0.progress = 1
            }
        case let r where r.success:
            if let url = r.outputURL,
               let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 {
                update(id) { $0.resultSize = size }
            }
            update(id) {
                $0.state = .succeeded
                $0.resultURL = r.outputURL
                $0.progress = 1
                $0.speedText = ""
                $0.etaText = ""
            }
            if currentSettings.deleteSource {
                try? FileManager.default.removeItem(at: job.inputURL)
            }
        default:
            fail(id, message: result.message)
        }

        finish(id)
    }

    private func fail(_ id: UUID, message: String) {
        update(id) {
            $0.state = .failed
            $0.error = message
        }
        finish(id)
    }

    private func cleanPartFile(_ outputURL: URL) {
        try? FileManager.default.removeItem(atPath: outputURL.path + ".part")
    }

    private static func formatETA(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    private func finish(_ id: UUID) {
        active -= 1
        NotificationCenter.default.post(name: .init("VideoOptimizer.jobFinished"), object: id)
        drain()
    }
}