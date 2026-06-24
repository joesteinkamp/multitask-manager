import Foundation

/// Detects Codex CLI sessions by scanning `~/.codex`.
///
/// The Codex CLI writes rollout transcripts as JSONL, commonly under
/// `~/.codex/sessions/<date>/rollout-*.jsonl`, plus a top-level `history.jsonl`.
/// Layout has shifted across versions, so this scans `~/.codex/sessions`
/// recursively (shallow depth) for recent `.jsonl` files and falls back to the
/// `~/.codex` root. Each rollout typically records the working directory under a
/// `cwd`/`workdir`/`cwd_path` key, which we read for the project name.
struct CodexDetector: SessionDetector {
    let id = "codex"
    let displayName = "Codex (CLI)"

    var maxAge: TimeInterval = 24 * 60 * 60

    private var root: URL {
        DetectorSupport.homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }

    func detect() -> [Session] {
        guard DetectorSupport.isDirectory(root) else { return [] }
        let cutoff = Date().addingTimeInterval(-maxAge)

        let transcripts = recentTranscripts(under: root, newerThan: cutoff)

        // Keep only the most-recent transcript per resolved project so duplicates
        // from the same workspace collapse into one row.
        var byProject: [String: Session] = [:]
        for url in transcripts {
            let mtime = DetectorSupport.modificationDate(of: url)
            let cwd = Self.readWorkingDirectory(from: url)
            let projectName = (cwd as NSString?)?.lastPathComponent
                ?? url.deletingPathExtension().lastPathComponent
            let key = cwd ?? url.path

            let session = Session(
                id: "codex:\(key)",
                title: projectName,
                projectName: projectName,
                projectPath: cwd,
                source: .codex,
                lastActivity: mtime
            )
            if let existing = byProject[key], existing.lastActivity >= mtime { continue }
            byProject[key] = session
        }
        return Array(byProject.values)
    }

    /// Recent `.jsonl` files under a directory tree, bounded so a huge history
    /// folder can't stall a refresh tick.
    private func recentTranscripts(under dir: URL, newerThan cutoff: Date) -> [URL] {
        let sessionsDir = dir.appendingPathComponent("sessions", isDirectory: true)
        let searchRoot = DetectorSupport.isDirectory(sessionsDir) ? sessionsDir : dir

        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = DetectorSupport.fileManager.enumerator(
            at: searchRoot,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var results: [URL] = []
        var scanned = 0
        for case let url as URL in enumerator {
            scanned += 1
            if scanned > 5_000 { break } // safety bound
            guard url.pathExtension == "jsonl" else { continue }
            let mtime = DetectorSupport.modificationDate(of: url)
            guard mtime >= cutoff else { continue }
            results.append(url)
        }
        return results
    }

    /// Scans the head of a transcript for a working-directory field under any of a
    /// few known key names.
    static func readWorkingDirectory(from transcript: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: transcript) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 16_384)) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return nil }

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
