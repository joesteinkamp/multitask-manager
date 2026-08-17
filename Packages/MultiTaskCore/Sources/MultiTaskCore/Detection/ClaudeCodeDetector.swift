import Foundation

/// Detects Claude Code CLI sessions by scanning `~/.claude/projects`.
///
/// Layout: `~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl`. The directory
/// name encodes the project working directory (path separators replaced with `-`),
/// and each transcript line carries a `cwd` field we can read for an exact project
/// path. The transcript file's modification time is the activity signal.
///
/// The transcript's filename stem is the harness's own session id, which is also
/// what the audit log records in its `session` field — so it is carried through as
/// `harnessSessionId` to give `AuditLogReader` an exact join key.
public struct ClaudeCodeDetector: SessionDetector {
    public let id = "claudeCode"
    public let displayName = "Claude Code (CLI)"

    /// Only surface transcripts touched within this window so old sessions don't
    /// pile up. The engine still classifies recent-but-quiet ones as needsAttention.
    public var maxAge: TimeInterval

    /// Root to scan. Injectable so tests can point at a fixture tree.
    public var projectsRoot: URL

    public init(maxAge: TimeInterval = 24 * 60 * 60, projectsRoot: URL? = nil) {
        self.maxAge = maxAge
        self.projectsRoot = projectsRoot ?? FileSupport.homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    public func detect() async -> DetectionOutcome {
        let root = projectsRoot
        guard FileSupport.isDirectory(root) else {
            return DetectionOutcome(degraded: DegradedReason(
                detectorId: id,
                message: "No Claude Code transcripts at \(root.path)"
            ))
        }

        let cutoff = Date().addingTimeInterval(-maxAge)
        var sessions: [Session] = []

        for projectDir in FileSupport.contents(of: root) where FileSupport.isDirectory(projectDir) {
            // Most-recent transcript represents the live session for this project.
            let transcripts = FileSupport.contents(of: projectDir)
                .filter { $0.pathExtension == "jsonl" }
            guard let latest = transcripts.first else { continue }

            let mtime = FileSupport.modificationDate(of: latest)
            guard mtime >= cutoff else { continue }

            let cwd = Self.readCWD(from: latest) ?? Self.decodeProjectPath(from: projectDir.lastPathComponent)
            let projectName = FileSupport.lastComponent(of: cwd)

            sessions.append(Session(
                id: "claude:\(latest.path)",
                title: projectName,
                projectName: projectName,
                projectPath: cwd,
                source: .claudeCode,
                lastActivity: mtime,
                transcriptPath: latest.path,
                harnessSessionId: latest.deletingPathExtension().lastPathComponent
            ))
        }
        return DetectionOutcome(sessions: sessions)
    }

    /// Reads the first `cwd` value out of a JSONL transcript without loading the
    /// whole (potentially large) file.
    public static func readCWD(from transcript: URL) -> String? {
        guard let text = FileSupport.readHead(of: transcript, limit: 16_384) else { return nil }
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
    public static func decodeProjectPath(from encoded: String) -> String {
        encoded.replacingOccurrences(of: "-", with: "/")
    }
}
