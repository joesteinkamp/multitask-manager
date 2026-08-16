import Foundation

/// What the harness audit log knows about one session, derived by
/// `AuditLogReader`.
///
/// This is the *derived index only*. The raw records carry truncated,
/// best-effort-redacted tool input and responses; those fields are dropped at
/// parse time and never reach this type (ground rule 5).
struct AuditActivity: Codable, Hashable {
    /// Timestamp of the most recent record for this session.
    var lastEventAt: Date

    /// Name of the tool used in the most recent `PreToolUse`/`PostToolUse`
    /// record — "Edit", "Bash", and so on. Nil when the last record carried no
    /// tool (e.g. `SessionEnd`).
    var lastToolName: String?

    /// How many records have been indexed for this session since the app
    /// started tailing. Not a lifetime total — the reader primes from the tail
    /// of the file rather than parsing history.
    var eventCount: Int

    /// When a `SessionEnd` record was seen. Non-nil means the run is
    /// *definitively* finished rather than merely quiet — the one place the app
    /// gets a fact instead of an inference. Cleared again if later records show
    /// the session resumed.
    var endedAt: Date?

    /// Working directory reported by the records, when present.
    var cwd: String?

    /// True when the join fell back to matching on working directory because no
    /// audit session id matched the detector's session id. Open question 1 in
    /// docs/PLAN.md: a cwd match is project-accurate but not session-accurate,
    /// so it is deliberately trusted less when resolving status.
    var matchedByWorkingDirectory: Bool = false

    /// Whether the audit log says this session has finished.
    var hasEnded: Bool { endedAt != nil }
}
