import Foundation

/// Detects Claude Code CLI sessions by scanning `~/.claude/projects`.
///
/// Layout: `~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl`. The directory
/// name encodes the project working directory (path separators replaced with `-`),
/// and each transcript line carries a `cwd` field we can read for an exact project
/// path. The transcript file's modification time is the activity signal.
struct ClaudeCodeDetector: SessionDetector {
    let id = "claudeCode"
    let displayName = "Claude Code (CLI)"

    /// Only surface transcripts touched within this window so old sessions don't
    /// pile up. The store still classifies recent-but-quiet ones as needsAttention.
    var maxAge: TimeInterval = 24 * 60 * 60

    private var projectsRoot: URL {
        DetectorSupport.homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    func detect() -> [Session] {
        let root = projectsRoot
        guard DetectorSupport.isDirectory(root) else { return [] }

        let cutoff = Date().addingTimeInterval(-maxAge)
        var sessions: [Session] = []

        for projectDir in DetectorSupport.contents(of: root) where DetectorSupport.isDirectory(projectDir) {
            // Most-recent transcript represents the live session for this project.
            let transcripts = DetectorSupport.contents(of: projectDir)
                .filter { $0.pathExtension == "jsonl" }
            guard let latest = transcripts.first else { continue }

            let mtime = DetectorSupport.modificationDate(of: latest)
            guard mtime >= cutoff else { continue }

            let cwd = Self.readCWD(from: latest) ?? Self.decodeProjectPath(from: projectDir.lastPathComponent)
            let projectName = (cwd as NSString?)?.lastPathComponent ?? projectDir.lastPathComponent

            let session = Session(
                id: "claude:\(latest.path)",
                title: projectName,
                projectName: projectName,
                projectPath: cwd,
                source: .claudeCode,
                lastActivity: mtime,
                transcriptPath: latest.path
            )
            sessions.append(session)
        }
        return sessions
    }

    /// Reads the first `cwd` value out of a JSONL transcript without loading the
    /// whole (potentially large) file.
    static func readCWD(from transcript: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: transcript) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 16_384)) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let cwd = obj["cwd"] as? String, !cwd.isEmpty
            else { continue }
            return cwd
        }
        return nil
    }

    /// Best-effort reconstruction of a project path from the encoded directory name
    /// (`/Users/me/dev/app` -> `-Users-me-dev-app`). Used only when the transcript
    /// has no `cwd` field; ambiguous if the real path contained dashes.
    static func decodeProjectPath(from encoded: String) -> String {
        encoded.replacingOccurrences(of: "-", with: "/")
    }
}
