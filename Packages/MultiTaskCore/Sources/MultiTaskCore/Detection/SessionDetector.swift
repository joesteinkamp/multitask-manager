import Foundation

/// Why a detector produced nothing useful. Distinguishing "I looked and there is
/// genuinely nothing running" from "the place I look no longer exists" is the whole
/// point: every upstream layout this app depends on has moved at least once, and an
/// empty array reports both cases identically.
public struct DegradedReason: Codable, Hashable, Sendable {
    /// Detector that degraded, matching `SessionDetector.id`.
    public var detectorId: String
    /// One line the UI can show verbatim, e.g. "no sessions found at ~/.codex/sessions".
    public var message: String

    public init(detectorId: String, message: String) {
        self.detectorId = detectorId
        self.message = message
    }
}

/// What one detector pass produced.
public struct DetectionOutcome: Sendable {
    public var sessions: [Session]
    /// Present when the detector could not do its job, absent when it simply found
    /// nothing. `sessions` may still be non-empty alongside a degraded reason if a
    /// detector partially succeeded.
    public var degraded: DegradedReason?

    public init(sessions: [Session] = [], degraded: DegradedReason? = nil) {
        self.sessions = sessions
        self.degraded = degraded
    }

    public static let empty = DetectionOutcome()
}

/// A pluggable source of sessions. Implementations scan some part of the system
/// (files, running apps, processes) and return the sessions they find.
///
/// Detectors must be cheap enough to run every refresh tick. They fail soft: if
/// their backing path or app is absent they return an empty outcome with a
/// `degraded` reason rather than throwing. Nothing a detector does may prevent the
/// rest of the list from rendering.
public protocol SessionDetector: Sendable {
    /// Stable identifier for the detector, used for enable/disable preferences.
    var id: String { get }

    /// Human-readable name shown in Settings.
    var displayName: String { get }

    /// Scan and return currently-known sessions. Runs off the main thread; `async`
    /// so detectors run in parallel and stay individually cancellable, which starts
    /// to matter once one of them shells out to `git`.
    func detect() async -> DetectionOutcome
}
