// ForceConvert.swift - The "convert anyway?" decision for a file dropped again after
// being refused by the bloat guard.

import Foundation

public enum ForceConvert {
    /// Whether dropping `url` again should prompt to force it through anyway: true only
    /// when the most recent past attempt at this exact file in `jobs` was refused by a
    /// guard (already efficient, or the result would have been bigger) — not when it's
    /// still in flight, genuinely failed, was cancelled, or already succeeded. Returns
    /// that past job (for its `.error`, which already explains why) or nil.
    public static func shouldPromptToForce(url: URL, among jobs: [Job]) -> Job? {
        let standardized = url.standardizedFileURL
        // The single most recent job for this file, whatever its state — not the most
        // recent one that happens to be a refusal, which would wrongly skip past a
        // later success (or failure, or cancellation) back to an older refusal.
        guard let mostRecent = jobs.last(where: { $0.inputURL.standardizedFileURL == standardized }) else {
            return nil
        }
        guard mostRecent.state == .alreadyOptimized || mostRecent.state == .discardedAsBlob else {
            return nil
        }
        return mostRecent
    }
}
