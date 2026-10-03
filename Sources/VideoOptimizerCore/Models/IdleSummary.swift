// IdleSummary.swift - What the drop zone shows once nothing is actively converting.

import Foundation

/// Pure so the "why did this job not produce anything" fallback logic is testable —
/// this project's AppKit layer has no test target, and this is exactly the kind of
/// priority-of-fallbacks logic that's easy to get subtly wrong (see history: a job
/// refused by the bloat guard used to fall through every case here and render as a
/// blank detail line, even though its `error` already held a precise explanation).
public enum IdleSummary {
    public static func headline(for jobs: [Job]) -> String {
        let succeeded = jobs.filter { $0.state == .succeeded }.count
        let skipped = jobs.filter { $0.state == .alreadyOptimized || $0.state == .discardedAsBlob }.count
        let failed = jobs.filter { $0.state == .failed }.count
        let cancelled = jobs.filter { $0.state == .cancelled }.count

        var parts: [String] = []
        if succeeded > 0 { parts.append("\(succeeded) converted") }
        if skipped > 0 { parts.append("\(skipped) already optimised") }
        if cancelled > 0 { parts.append("\(cancelled) stopped") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.isEmpty ? "Drop video files here" : parts.joined(separator: " · ")
    }

    /// A succeeded batch's before/after summary takes priority (it's this session's
    /// headline result); otherwise the most recent failure's or refusal's own message,
    /// which already explains exactly why nothing was produced — never a blank line
    /// just because the only thing that happened was a refusal, not a failure.
    public static func detail(for jobs: [Job]) -> String {
        let converted = jobs.filter { $0.state == .succeeded }
        if !converted.isEmpty {
            let before = converted.reduce(Int64(0)) { $0 + $1.inputSize }
            let after = converted.reduce(Int64(0)) { $0 + ($1.resultSize ?? $1.inputSize) }
            guard before > 0 else { return "" }
            let percent = Int((1 - Double(after) / Double(before)) * 100)
            return "\(formatBytes(before)) → \(formatBytes(after)) (−\(percent)%) · click to show in Finder"
        }
        if let failed = jobs.last(where: { $0.state == .failed }), !failed.error.isEmpty {
            return failed.error
        }
        if let skipped = jobs.last(where: { $0.state == .alreadyOptimized || $0.state == .discardedAsBlob }),
           !skipped.error.isEmpty {
            return skipped.error
        }
        return ""
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
