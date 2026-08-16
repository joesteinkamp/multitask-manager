import Foundation

/// Detects Codex CLI sessions by scanning `~/.codex`.
///
/// The Codex CLI writes rollout transcripts as JSONL, currently under
/// `~/.codex/sessions/<yyyy>/<mm>/<dd>/rollout-<timestamp>-<session-uuid>.jsonl`,
/// plus a top-level `history.jsonl`. Layout has shifted across versions, so this
/// scans `~/.codex/sessions` recursively for recent `.jsonl` files and falls back
/// to the `~/.codex` root. Each rollout records the working directory under a
/// `cwd`/`workdir`/`cwd_path` key, which we read for the project name.
///
/// The session uuid trailing the rollout filename is the same id the audit log
/// records, so it is carried as `harnessSessionId` for an exact join.
public struct CodexDetector: SessionDetector {
    public let id = "codex"
    public let displayName = "Codex (CLI)"

    public var maxAge: TimeInterval
    public var root: URL

    public init(maxAge: TimeInterval = 24 * 60 * 60, root: URL? = nil) {
        self.maxAge = maxAge
        self.root = root ?? FileSupport.homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }

    public func detect() async -> DetectionOutcome {
        guard FileSupport.isDirectory(root) else {
            return DetectionOutcome(degraded: DegradedReason(
                detectorId: id,
                message: "No Codex sessions at \(root.path)"
            ))
        }
        let cutoff = Date().addingTimeInterval(-maxAge)
        let transcripts = recentTranscripts(under: root, newerThan: cutoff)

        // Keep only the most-recent transcript per resolved project so duplicates
        // from the same workspace collapse into one row.
        var byProject: [String: Session] = [:]
        for url in transcripts {
            let mtime = FileSupport.modificationDate(of: url)
            let cwd = Self.readWorkingDirectory(from: url)
            let projectName = cwd.map(FileSupport.lastComponent(of:))
                ?? url.deletingPathExtension().lastPathComponent
            let key = cwd ?? url.path

            if let existing = byProject[key], existing.lastActivity >= mtime { continue }
            byProject[key] = Session(
                id: "codex:\(key)",
                title: projectName,
                projectName: projectName,
                projectPath: cwd,
                source: .codex,
                lastActivity: mtime,
                transcriptPath: url.path,
                harnessSessionId: Self.sessionId(fromRolloutFilename: url.lastPathComponent)
            )
        }
        return DetectionOutcome(sessions: Array(byProject.values))
    }

    /// Recent `.jsonl` files under a directory tree, bounded so a huge history
    /// folder can't stall a refresh tick.
    private func recentTranscripts(under dir: URL, newerThan cutoff: Date) -> [URL] {
        let sessionsDir = dir.appendingPathComponent("sessions", isDirectory: true)
        let searchRoot = FileSupport.isDirectory(sessionsDir) ? sessionsDir : dir

        guard let enumerator = FileSupport.fileManager.enumerator(
            at: searchRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var results: [URL] = []
        var scanned = 0
        for case let url as URL in enumerator {
            scanned += 1
            if scanned > 5_000 { break } // safety bound
            guard url.pathExtension == "jsonl" else { continue }
            let mtime = FileSupport.modificationDate(of: url)
            guard mtime >= cutoff else { continue }
            results.append(url)
        }
        return results
    }

    /// Extracts the trailing session uuid from a rollout filename.
    ///
    /// `rollout-2026-07-25T19-45-09-019f9acf-6091-7663-b483-4b0fec2f778b.jsonl`
    /// → `019f9acf-6091-7663-b483-4b0fec2f778b`. The timestamp ahead of it also
    /// contains dashes, so this matches on the uuid's own shape (5 hex groups of
    /// 8-4-4-4-12) taken from the end, rather than splitting on dashes.
    public static func sessionId(fromRolloutFilename filename: String) -> String? {
        let stem = filename.hasSuffix(".jsonl") ? String(filename.dropLast(6)) : filename
        let parts = stem.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 5 else { return nil }
        let tail = parts.suffix(5).map(String.init)
        let widths = [8, 4, 4, 4, 12]
        for (part, width) in zip(tail, widths) {
            guard part.count == width,
                  part.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
            else { return nil }
        }
        return tail.joined(separator: "-")
    }

    /// Scans the head of a transcript for a working-directory field under any of a
    /// few known key names.
    public static func readWorkingDirectory(from transcript: URL) -> String? {
        guard let text = FileSupport.readHead(of: transcript, limit: 16_384) else { return nil }

        let candidateKeys = ["cwd", "workdir", "cwd_path", "working_directory"]
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            for key in candidateKeys {
                if let value = obj[key] as? String, !value.isEmpty { return value }
                // Some rollouts nest metadata one level deep.
                if let nested = obj["payload"] as? [String: Any],
                   let value = nested[key] as? String, !value.isEmpty { return value }
            }
        }
        return nil
    }
}
